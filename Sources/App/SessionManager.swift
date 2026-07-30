import AVFoundation
import SwiftUI
import UIKit

/// The app-side brain: owns the recorder and the model, mirrors every state
/// change into the App Group store, and executes commands the keyboard sends.
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var modelState: Transcriber.State = .unloaded
    @Published private(set) var transcripts: [FlowResult] = []
    @Published private(set) var micLevel: Float = 0
    @Published var lastError: String?
    @Published private(set) var micPermission = AVAudioApplication.shared.recordPermission
    /// Mirrors FlowStore.tone; the keyboard's tone chip changes it too.
    @Published var tone: FlowTone = .formal {
        didSet { if store.tone != tone { store.tone = tone } }
    }

    let store = FlowStore()
    private let bus = DarwinBus()
    private let recorder = AudioRecorder()
    private var transcriber: Transcriber?
    private var gemma: GemmaEngine?
    private var heartbeatTimer: Timer?
    private var idleTimer: Timer?
    private var levelWriteGate = Date.distantPast
    /// Serial chain of window transcriptions for the segment in progress.
    /// Long dictations transcribe while the user is still talking; at stop
    /// only the tail remains. Each window's samples are owned by its task
    /// and freed as soon as it finishes.
    private var windowChain: Task<String, Never>?

    /// Sessions end themselves after this long with no dictation, so an
    /// abandoned session doesn't hold the mic (and the orange dot) all day.
    static let idleTimeout: TimeInterval = 15 * 60

    /// UserDefaults keys: dictation language (whisper code or "auto") and
    /// model choice ("turbo" | "accurate"). Tone lives in FlowStore
    /// instead — the keyboard can change it too.
    static let languageKey = "flow.language"
    static let modelKey = "flow.model"

    /// Human name + size of the currently selected model, for download UI.
    static func selectedModelDescription() -> String {
        switch UserDefaults.standard.string(forKey: modelKey) {
        case "accurate": "large-v3 (950 MB)"
        case "gemma": "Gemma 4 (4.1 GB)"
        default: "large-v3-turbo (626 MB)"
        }
    }

    init() {
        transcripts = store.results
        tone = store.tone
        refreshSetupState()
        // A fresh launch means any previous session died with the process.
        publish(.idle)
        bus.observe(Flow.commandNotification) { [weak self] in
            self?.drainCommands()
        }
        // Holding ~1.5 GB of idle weights is fine on a 12 GB phone until
        // iOS says otherwise — then drop them (only while no session runs).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .idle else { return }
                let transcriber = self.transcriber
                Task { await transcriber?.unload() }
            }
        }
    }

    var keyboardSeen: Bool { store.keyboardSeen }

    /// Whether the HopBoard keyboard is enabled in Settings — readable
    /// live from the system's enabled-keyboards list, so the checklist
    /// updates the moment the user returns from Settings.
    @Published private(set) var keyboardEnabled = false

    func refreshSetupState() {
        micPermission = AVAudioApplication.shared.recordPermission
        let keyboards = UserDefaults.standard.array(forKey: "AppleKeyboards") as? [String] ?? []
        keyboardEnabled = keyboards.contains { $0.contains("io.zhoulab.hopboard.keyboard") }
        objectWillChange.send()
    }

    // MARK: session lifecycle

    func startSession() async {
        guard state == .idle else { return }
        lastError = nil

        guard await ensureMicPermission() else {
            lastError = "Microphone access is required. Enable it in Settings → HopBoard."
            return
        }

        publish(.loading)
        store.modelStatus = "Preparing model…"
        // Heartbeat from the FIRST moment, not from session-ready: model
        // loading has quiet stretches with no state writes, and a stale
        // heartbeat made the keyboard flicker to "Start Session" mid-load.
        startHeartbeat()

        let choice = UserDefaults.standard.string(forKey: Self.modelKey) ?? "turbo"
        if choice == "gemma" {
            // Experimental audio-LLM path; Whisper's weights get freed.
            if let transcriber { Task { await transcriber.unload() } }
            let gemma = self.gemma ?? GemmaEngine { [weak self] modelState in
                Task { @MainActor in self?.applyModelState(modelState) }
            }
            self.gemma = gemma
            await gemma.load()
            guard await gemma.isReady else {
                publish(.idle)
                return
            }
        } else {
            if let gemma { Task { await gemma.unload() } }
            let transcriber = self.transcriber ?? Transcriber { [weak self] modelState in
                Task { @MainActor in self?.applyModelState(modelState) }
            }
            self.transcriber = transcriber
            let model = choice == "accurate"
                ? Transcriber.accurateModel : Transcriber.turboModel
            await transcriber.load(model: model)
            guard await transcriber.isReady else {
                publish(.idle)
                return
            }
        }

        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.updateLevel(level) }
        }
        recorder.onInterruption = { [weak self] in
            self?.endSession(reason: "Audio was interrupted — session ended.")
        }
        recorder.onWindow = { [weak self] window in
            Task { @MainActor in self?.enqueueWindow(window) }
        }
        // Gemma's audio encoder hits device batch limits past ~25 s of
        // audio — feed it shorter windows; Whisper keeps its native 30 s.
        recorder.windowSeconds = choice == "gemma" ? 12 : 30
        do {
            try recorder.start()
        } catch {
            lastError = "Could not start the microphone: \(error.localizedDescription)"
            publish(.idle)
            return
        }

        publish(.ready)
        startHeartbeat()
        touchIdleTimer()
    }

    func endSession(reason: String? = nil) {
        guard state != .idle else { return }
        recorder.stop()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        windowChain = nil
        if let reason { lastError = reason }
        publish(.idle)
        // The model stays loaded between sessions — reloading on every
        // session showed the user a "loading/optimizing" wait each time.
        // Memory pressure (observed in init) is what triggers an unload.
    }

    // MARK: segments (driven by the keyboard or the in-app test button)

    func beginSegment() {
        guard state == .ready else { return }
        windowChain = nil
        recorder.beginSegment()
        publish(.recording)
        touchIdleTimer()
    }

    /// A completed 30 s window rolled out mid-dictation: transcribe it now,
    /// chained behind earlier windows so the texts stitch in order.
    private func enqueueWindow(_ window: [Float]) {
        guard state == .recording else { return }
        touchIdleTimer()   // a long monologue is activity, not idleness
        let previous = windowChain
        windowChain = Task { [weak self] in
            let prefix = await previous?.value ?? ""
            let text = (try? await self?.transcribeSamples(window)) ?? ""
            return [prefix, text].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// One entry point for every chunk of audio, routed to whichever
    /// engine the session was started with.
    private func transcribeSamples(_ samples: [Float]) async throws -> String {
        let language = UserDefaults.standard.string(forKey: Self.languageKey)
        if UserDefaults.standard.string(forKey: Self.modelKey) == "gemma", let gemma {
            let text = try await gemma.transcribe(samples, language: language, tone: store.tone)
            if text.isEmpty, samples.count > 16000 {
                // A second of real audio should never transcribe to nothing
                // — surface what the engine actually did.
                lastError = "Gemma returned nothing — \(await gemma.lastDiagnostic)"
            }
            return text
        }
        return try await transcriber?.transcribe(samples, language: language) ?? ""
    }

    func finishSegment() {
        guard state == .recording else { return }
        let tail = recorder.takeSegment()
        publish(.transcribing)
        let tone = store.tone
        let previous = windowChain
        windowChain = nil
        Task {
            let prefix = await previous?.value ?? ""
            // Watchdog: engines (Gemma especially) can grind for minutes.
            // After 90 s release the keyboard; if the engine eventually
            // finishes, the text arrives as a late result — the keyboard
            // offers it as an Insert pill instead of losing it.
            // Errors must surface, not vanish into try? — a throwing engine
            // looked identical to silence from the keyboard.
            let work = Task { [weak self] () -> String in
                do {
                    return try await self?.transcribeSamples(tail) ?? ""
                } catch {
                    await MainActor.run { [weak self] in
                        self?.lastError = "Transcription failed: \(error.localizedDescription)"
                    }
                    return ""
                }
            }
            let raced = await withTaskGroup(of: String?.self) { group in
                group.addTask { await work.value }
                group.addTask {
                    try? await Task.sleep(for: .seconds(90))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            var tailText = ""
            if let raced {
                tailText = raced
            } else {
                lastError = "Transcription is taking unusually long — if it finishes, the text will appear on the keyboard as an Insert button."
                Task { [weak self] in
                    let late = await work.value
                    guard let self, !late.isEmpty else { return }
                    let result = FlowResult(id: UUID(),
                                            text: tone.apply(to: FlowText.normalizeCJKPunctuation(late)),
                                            finishedAt: Date().timeIntervalSince1970)
                    self.store.append(result)
                    self.transcripts = self.store.results
                    self.bus.post(Flow.stateNotification)
                }
            }
            let text = tone.apply(to: FlowText.normalizeCJKPunctuation(
                [prefix, tailText].filter { !$0.isEmpty }.joined(separator: " ")))
            // Always deliver a result — an empty one releases the keyboard
            // from its spinner instead of leaving it waiting forever.
            let result = FlowResult(id: UUID(), text: text, finishedAt: Date().timeIntervalSince1970)
            store.append(result)
            transcripts = store.results
            if state == .transcribing { publish(.ready) }
            bus.post(Flow.stateNotification)
            touchIdleTimer()
        }
    }

    func cancelSegment() {
        guard state == .recording else { return }
        recorder.cancelSegment()
        windowChain = nil
        publish(.ready)
    }

    func clearHistory() {
        store.clearResults()
        transcripts = []
    }

    // MARK: keyboard commands

    private func drainCommands() {
        // The keyboard's tone chip writes straight to the store and pings
        // this notification; keep the app UI in sync even with no command.
        if tone != store.tone { tone = store.tone }
        // Process every queued command in order — a fast start+stop pair
        // becomes a legitimate (short, likely empty) dictation instead of a
        // lost start and a stuck keyboard.
        for command in store.takeCommands() {
            switch command.action {
            case .startSegment: beginSegment()
            case .stopSegment: finishSegment()
            case .cancelSegment: cancelSegment()
            case .endSession: endSession()
            }
        }
    }

    // MARK: plumbing

    private func publish(_ new: SessionState) {
        state = new
        store.state = new
        store.heartbeat = Date()
        if new == .idle { heartbeatTimer?.invalidate() }
        bus.post(Flow.stateNotification)
    }

    private func applyModelState(_ new: Transcriber.State) {
        modelState = new
        switch new {
        case .unloaded:
            store.modelStatus = ""
        case .downloading(let fraction):
            store.modelStatus = "Downloading \(Self.selectedModelDescription()) \(Int(fraction * 100))%…"
        case .loading:
            store.modelStatus = "Loading model…"
        case .ready:
            store.modelStatus = ""
        case .failed(let message):
            store.modelStatus = ""
            lastError = "Model failed to load: \(message)"
        }
        store.heartbeat = Date()
        bus.post(Flow.stateNotification)
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state != .idle else { return }
                self.store.heartbeat = Date()
            }
        }
    }

    private func touchIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.endSession(reason: "Session ended after \(Int(Self.idleTimeout / 60)) minutes of inactivity.")
            }
        }
    }

    private func updateLevel(_ level: Float) {
        micLevel = level
        // Shared-defaults writes are plist rewrites — cap them at 5 Hz.
        let now = Date()
        if now.timeIntervalSince(levelWriteGate) > 0.2 {
            levelWriteGate = now
            store.micLevel = level
        }
    }

    private func ensureMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            micPermission = .granted
            return true
        case .denied:
            micPermission = .denied
            return false
        default:
            let granted = await AVAudioApplication.requestRecordPermission()
            micPermission = AVAudioApplication.shared.recordPermission
            return granted
        }
    }
}
