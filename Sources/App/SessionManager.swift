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
    /// "Optimizing for Neural Engine" vs plain "Loading model" — they are
    /// different waits (minutes vs seconds) and are labeled as such.
    @Published private(set) var loadingLabel = "Loading model"
    /// When the current transcription started (drives the app's timer).
    @Published private(set) var transcribingSince: Date?
    @Published var lastError: String?
    @Published private(set) var micPermission = AVAudioApplication.shared.recordPermission
    /// Mirrors FlowStore.tone; the keyboard's tone chip changes it too.
    @Published var tone: FlowTone = .formal {
        didSet { if store.tone != tone { store.tone = tone } }
    }
    /// Mirrors FlowStore.language ("auto" or a whisper code); the
    /// keyboard's language chip changes it too.
    @Published var language: String = "auto" {
        didSet { if store.language != language { store.language = language } }
    }

    let store = FlowStore()
    private let bus = DarwinBus()
    private let recorder = AudioRecorder()
    private var transcriber: Transcriber?
    private var gemma: GemmaEngine?
    private var litert: LiteRTEngine?
    /// Availability-erased storage: a stored property can't be typed with
    /// an @available(iOS 26) class while the target deploys to 17.
    private var appleBox: AnyObject?
    @available(iOS 26.0, *)
    private var apple: AppleSpeechEngine? {
        get { appleBox as? AppleSpeechEngine }
        set { appleBox = newValue }
    }
    private var heartbeatTimer: Timer?
    private var idleTimer: Timer?
    private var levelWriteGate = Date.distantPast
    /// Monotonic session epoch: every start/end/model-switch increments
    /// it, and every async continuation validates it before touching live
    /// state. Work from a dead epoch may add to history but can never
    /// change the current session or reach the keyboard.
    private var sessionEpoch = 0

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
    static let gemmaThinkingKey = "flow.gemmaThinking"
    static let gemmaThinkingBudgetKey = "flow.gemmaThinkingBudget"
    static let gemmaCustomInstructionKey = "flow.gemmaCustomInstruction"
    static let litertVariantKey = "flow.litertVariant"

    static func litertVariant() -> String {
        UserDefaults.standard.string(forKey: litertVariantKey) ?? "e2b"
    }

    /// Advanced mode: a non-blank custom instruction replaces the built-in
    /// per-language/tone instruction verbatim. Blank = defaults.
    static func gemmaCustomInstruction() -> String? {
        let text = UserDefaults.standard.string(forKey: gemmaCustomInstructionKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// Max thought tokens per dictation window (0 = unlimited). Defaults to
    /// Brief: the ~170-token unlimited thought is checklist boilerplate that
    /// dominates decode time, and forced-close answers matched unlimited
    /// answers in harness validation.
    static func gemmaThinkingBudget() -> Int {
        (UserDefaults.standard.object(forKey: gemmaThinkingBudgetKey) as? Int) ?? 48
    }

    /// Human name + size of the currently selected model, for download UI.
    static func selectedModelDescription() -> String {
        switch UserDefaults.standard.string(forKey: modelKey) {
        case "accurate": "large-v3 (950 MB)"
        case "gemma": "Gemma 4 (4.1 GB)"
        case "litert": litertVariant() == "e4b"
            ? "Gemma 4 E4B LiteRT (3.7 GB)" : "Gemma 4 E2B LiteRT (2.6 GB)"
        case "apple": "Apple's speech model (system download)"
        default: "large-v3-turbo (626 MB)"
        }
    }

    init() {
        transcripts = store.results
        tone = store.tone
        // Migrate the pre-chip UserDefaults language into the shared store
        // (didSet doesn't fire during init, so seed the store explicitly).
        language = store.language.isEmpty
            ? UserDefaults.standard.string(forKey: Self.languageKey) ?? "auto"
            : store.language
        store.language = language
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
                let gemma = self.gemma
                let litert = self.litert
                Task { await transcriber?.unload() }
                Task { await gemma?.unload() }
                Task { await litert?.unload() }
                self.unloadAppleEngine()
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
        sessionEpoch += 1
        let epoch = sessionEpoch
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
            // Experimental audio-LLM path; the other engines' weights are
            // freed — one resident model at a time.
            if let transcriber { Task { await transcriber.unload() } }
            if let litert { Task { await litert.unload() } }
            unloadAppleEngine()
            let gemma = self.gemma ?? GemmaEngine { [weak self] modelState in
                Task { @MainActor in self?.applyModelState(modelState) }
            }
            self.gemma = gemma
            gemma.abortFlag.set(false)
            await gemma.load()
            guard epoch == sessionEpoch else { return }
            guard await gemma.isReady else {
                publish(.idle)
                return
            }
        } else if choice == "apple" {
            guard #available(iOS 26.0, *) else {
                lastError = "Apple's transcriber needs iOS 26."
                publish(.idle)
                return
            }
            if let transcriber { Task { await transcriber.unload() } }
            if let gemma { Task { await gemma.unload() } }
            if let litert { Task { await litert.unload() } }
            let apple = self.apple ?? AppleSpeechEngine { [weak self] modelState in
                Task { @MainActor in self?.applyModelState(modelState) }
            }
            self.apple = apple
            apple.abortFlag.set(false)
            await apple.load(language: currentLanguage())
            guard epoch == sessionEpoch else { return }
            guard await apple.isReady else {
                publish(.idle)
                return
            }
        } else if choice == "litert" {
            if let transcriber { Task { await transcriber.unload() } }
            if let gemma { Task { await gemma.unload() } }
            unloadAppleEngine()
            let litert = self.litert ?? LiteRTEngine { [weak self] modelState in
                Task { @MainActor in self?.applyModelState(modelState) }
            }
            self.litert = litert
            litert.abortFlag.set(false)
            await litert.load(variant: Self.litertVariant())
            guard epoch == sessionEpoch else { return }
            guard await litert.isReady else {
                publish(.idle)
                return
            }
        } else {
            if let gemma { Task { await gemma.unload() } }
            if let litert { Task { await litert.unload() } }
            unloadAppleEngine()
            let transcriber = self.transcriber ?? Transcriber { [weak self] modelState in
                Task { @MainActor in self?.applyModelState(modelState) }
            }
            self.transcriber = transcriber
            let model = choice == "accurate"
                ? Transcriber.accurateModel : Transcriber.turboModel
            await transcriber.load(model: model)
            guard epoch == sessionEpoch else { return }
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
        // Gemma's 12 s window is a latency/memory choice, NOT a batch limit:
        // audio tokenizes at ~25 tok/s (34 s = ~850 tokens, evals fine even
        // at n_batch 1024 on the Mac harness — the old device -3 was the
        // background-Metal failure, misread as overflow). Shorter windows
        // bound the post-stop tail and keep CPU bursts small while
        // backgrounded; n_ctx 4096 could take ~2 min per call if we ever
        // want fewer seams. Whisper keeps its native 30 s.
        recorder.windowSeconds = choice == "gemma" || choice == "litert" ? 12 : 30
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
        sessionEpoch += 1
        gemma?.abortFlag.set(true)
        litert?.abort()
        if #available(iOS 26.0, *) { apple?.abortFlag.set(true) }
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
        let epoch = sessionEpoch
        windowChain = Task { [weak self] in
            let prefix = await previous?.value ?? ""
            // A window queued for a dead session must not burn minutes of
            // CPU; its session can never use the text.
            guard epoch == self?.sessionEpoch else { return prefix }
            let text = (try? await self?.transcribeSamples(window)) ?? ""
            return [prefix, text].filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// One entry point for every chunk of audio, routed to whichever
    /// engine the session was started with.
    /// Read the keychain-backed value LIVE, not the @Published mirror: the
    /// keyboard's chip changes it while the app is backgrounded, and every
    /// window must honor the latest choice.
    private func currentLanguage() -> String {
        let stored = store.language
        return stored.isEmpty ? language : stored
    }

    private func transcribeSamples(_ samples: [Float]) async throws -> String {
        let language: String? = currentLanguage()
        switch UserDefaults.standard.string(forKey: Self.modelKey) {
        case "gemma" where gemma != nil:
            let gemma = gemma!
            let text = try await gemma.transcribe(
                samples, language: language, tone: store.tone,
                thinking: UserDefaults.standard.bool(forKey: Self.gemmaThinkingKey),
                thinkingBudget: Self.gemmaThinkingBudget(),
                customInstruction: Self.gemmaCustomInstruction())
            if text.isEmpty, samples.count > 16000 {
                // A second of real audio should never transcribe to nothing
                // — surface what the engine actually did.
                lastError = "Gemma returned nothing — \(gemma.diag.get())"
            }
            return text
        case "litert" where litert != nil:
            let litert = litert!
            let text = try await litert.transcribe(
                samples, language: language, tone: store.tone,
                customInstruction: Self.gemmaCustomInstruction())
            if text.isEmpty, samples.count > 16000 {
                lastError = "LiteRT returned nothing — \(litert.diag.get())"
            }
            return text
        case "apple":
            guard #available(iOS 26.0, *), let apple else { return "" }
            // No empty-result banner here (Whisper parity): a quiet or
            // unintelligible window legitimately transcribes to nothing.
            // Real failures throw, and the timeout banner still names the
            // engine stage.
            return try await apple.transcribe(samples, language: language)
        default:
            return try await transcriber?.transcribe(samples, language: language) ?? ""
        }
    }

    /// Which engine's breadcrumb to blame in the timeout banner.
    private func engineStage() -> String {
        switch UserDefaults.standard.string(forKey: Self.modelKey) {
        case "gemma": gemma?.diag.get() ?? "gemma engine"
        case "litert": litert?.diag.get() ?? "litert engine"
        case "apple":
            if #available(iOS 26.0, *) { apple?.diag.get() ?? "apple engine" }
            else { "apple engine" }
        default: "whisper engine"
        }
    }

    private func unloadAppleEngine() {
        if #available(iOS 26.0, *), let apple {
            Task { await apple.unload() }
        }
    }

    func finishSegment() {
        guard state == .recording else { return }
        let tail = recorder.takeSegment()
        publish(.transcribing)
        let tone = store.tone
        let previous = windowChain
        windowChain = nil
        let epoch = sessionEpoch
        Task {
            let prefix = await previous?.value ?? ""
            // Watchdog: engines (Gemma especially) can grind for minutes.
            // After 90 s release the keyboard; if the engine eventually
            // finishes, the text arrives as a late result — the keyboard
            // offers it as an Insert pill instead of losing it.
            // Errors must surface, not vanish into try? — a throwing engine
            // looked identical to silence from the keyboard.
            // Watchdog wraps the ENTIRE pipeline — window-chain await
            // included; racing only the tail left the keyboard hung when a
            // queued window was the slow part.
            let work = Task { [weak self] () -> String in
                let prefix = await previous?.value ?? ""
                do {
                    let tailText = try await self?.transcribeSamples(tail) ?? ""
                    return [prefix, tailText].filter { !$0.isEmpty }.joined(separator: " ")
                } catch {
                    await MainActor.run { [weak self] in
                        self?.lastError = "Transcription failed: \(error.localizedDescription)"
                    }
                    return prefix
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
            var joined = ""
            if let raced {
                joined = raced
            } else {
                let stage = engineStage()
                lastError = "Transcription timed out after 90s at stage: \(stage). If it finishes, the text appears as an Insert button on the keyboard."
                Task { [weak self] in
                    let late = await work.value
                    guard let self, !late.isEmpty else { return }
                    let result = FlowResult(id: UUID(),
                                            text: tone.apply(to: FlowText.normalizeCJKPunctuation(late)),
                                            finishedAt: Date().timeIntervalSince1970)
                    self.store.append(result)
                    if epoch != self.sessionEpoch {
                        self.store.lastConsumedResultID = result.id
                    }
                    self.transcripts = self.store.results
                    self.bus.post(Flow.stateNotification)
                }
            }
            let text = tone.apply(to: FlowText.normalizeCJKPunctuation(joined))
            guard epoch == self.sessionEpoch else {
                // The session this belonged to is gone: preserve the text in
                // the app's history, pre-consumed so the keyboard never
                // auto-inserts or offers it in a NEW session.
                if !text.isEmpty {
                    let result = FlowResult(id: UUID(), text: text,
                                            finishedAt: Date().timeIntervalSince1970)
                    self.store.append(result)
                    self.store.lastConsumedResultID = result.id
                    self.transcripts = self.store.results
                }
                return
            }
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
        // The keyboard's chips write straight to the store and ping this
        // notification; keep the app UI in sync even with no command.
        if tone != store.tone { tone = store.tone }
        let storedLanguage = store.language
        if !storedLanguage.isEmpty, language != storedLanguage { language = storedLanguage }
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
        if new == .transcribing {
            if transcribingSince == nil { transcribingSince = Date() }
        } else {
            transcribingSince = nil
        }
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
            let choice = UserDefaults.standard.string(forKey: Self.modelKey) ?? "turbo"
            if choice == "gemma" || choice == "litert" || choice == "apple" {
                loadingLabel = "Loading model"
            } else {
                let model = choice == "accurate" ? Transcriber.accurateModel : Transcriber.turboModel
                loadingLabel = Transcriber.hasOptimized(model)
                    ? "Loading model" : "Optimizing for Neural Engine"
            }
            store.modelStatus = loadingLabel + "…"
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
