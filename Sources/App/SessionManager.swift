import AVFoundation
import SwiftUI

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

    let store = FlowStore()
    private let bus = DarwinBus()
    private let recorder = AudioRecorder()
    private var transcriber: Transcriber?
    private var heartbeatTimer: Timer?
    private var idleTimer: Timer?
    private var levelWriteGate = Date.distantPast

    /// Sessions end themselves after this long with no dictation, so an
    /// abandoned session doesn't hold the mic (and the orange dot) all day.
    static let idleTimeout: TimeInterval = 15 * 60

    /// UserDefaults key for the user's custom Whisper initial prompt
    /// (edited in ContentView via @AppStorage).
    static let promptKey = "flow.promptText"

    init() {
        transcripts = store.results
        // A fresh launch means any previous session died with the process.
        publish(.idle)
        bus.observe(Flow.commandNotification) { [weak self] in
            self?.drainCommands()
        }
    }

    var keyboardSeen: Bool { store.keyboardSeen }

    // MARK: session lifecycle

    func startSession() async {
        guard state == .idle else { return }
        lastError = nil

        guard await ensureMicPermission() else {
            lastError = "Microphone access is required. Enable it in Settings → FlowBoard."
            return
        }

        publish(.loading)
        store.modelStatus = "Preparing model…"

        let transcriber = self.transcriber ?? Transcriber { [weak self] modelState in
            Task { @MainActor in self?.applyModelState(modelState) }
        }
        self.transcriber = transcriber
        await transcriber.load()
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
        if let reason { lastError = reason }
        publish(.idle)
    }

    // MARK: segments (driven by the keyboard or the in-app test button)

    func beginSegment() {
        guard state == .ready else { return }
        recorder.beginSegment()
        publish(.recording)
        touchIdleTimer()
    }

    func finishSegment() {
        guard state == .recording else { return }
        let samples = recorder.takeSegment()
        publish(.transcribing)
        let prompt = UserDefaults.standard.string(forKey: Self.promptKey)
        Task {
            var text = ""
            do {
                text = try await transcriber?.transcribe(samples, prompt: prompt) ?? ""
            } catch {
                lastError = "Transcription failed: \(error.localizedDescription)"
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
        publish(.ready)
    }

    func clearHistory() {
        store.clearResults()
        transcripts = []
    }

    // MARK: keyboard commands

    private func drainCommands() {
        guard let command = store.takeCommand() else { return }
        switch command.action {
        case .startSegment: beginSegment()
        case .stopSegment: finishSegment()
        case .cancelSegment: cancelSegment()
        case .endSession: endSession()
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
            store.modelStatus = "Downloading model \(Int(fraction * 100))% of 626 MB…"
        case .loading:
            store.modelStatus = "Optimizing for Neural Engine (first time takes a minute)…"
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
