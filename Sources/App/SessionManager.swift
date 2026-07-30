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

        let transcriber = self.transcriber ?? Transcriber { [weak self] modelState in
            Task { @MainActor in self?.applyModelState(modelState) }
        }
        self.transcriber = transcriber
        let model = UserDefaults.standard.string(forKey: Self.modelKey) == "accurate"
            ? Transcriber.accurateModel : Transcriber.turboModel
        await transcriber.load(model: model)
        guard await transcriber.isReady else {
            publish(.idle)
            return
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
        let language = UserDefaults.standard.string(forKey: Self.languageKey)
        let transcriber = self.transcriber
        let previous = windowChain
        windowChain = Task {
            let prefix = await previous?.value ?? ""
            let text = (try? await transcriber?.transcribe(window, language: language)) ?? ""
            return [prefix, text].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    func finishSegment() {
        guard state == .recording else { return }
        let tail = recorder.takeSegment()
        publish(.transcribing)
        let language = UserDefaults.standard.string(forKey: Self.languageKey)
        let tone = store.tone
        let previous = windowChain
        windowChain = nil
        Task {
            let prefix = await previous?.value ?? ""
            var tailText = ""
            do {
                tailText = try await transcriber?.transcribe(tail, language: language) ?? ""
            } catch {
                lastError = "Transcription failed: \(error.localizedDescription)"
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
        bus.post(Flow.stateNotification)
    }

    private func applyModelState(_ new: Transcriber.State) {
        modelState = new
        switch new {
        case .unloaded:
            store.modelStatus = ""
        case .downloading(let fraction):
            store.modelStatus = "Downloading model \(Int(fraction * 100))%…"
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
