import Foundation
import UIKit

@MainActor
final class KeyboardModel: ObservableObject {
    enum UIState: Equatable {
        case needsFullAccess
        case noSession
        case loading(String)
        case ready
        case recording
        case transcribing
    }

    @Published private(set) var state: UIState = .noSession
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var showsGlobe = true
    @Published private(set) var justInserted = false
    @Published private(set) var tone: FlowTone = .formal
    /// Recent non-empty dictations, newest first — browsable from the
    /// keyboard so a dictation that landed nowhere (focus lost, keyboard
    /// dismissed mid-transcribe) is recoverable with a preview.
    @Published private(set) var historyItems: [FlowResult] = []
    @Published var showingHistory = false
    /// When the current recording started — drives the live timer that
    /// makes the recording state unmissable.
    @Published private(set) var recordingStartedAt: Date?

    private weak var controller: KeyboardViewController?
    /// The UIKit globe key needs the controller for handleInputModeList.
    var globeController: KeyboardViewController? { controller }
    private let store = FlowStore()
    private let bus = DarwinBus()
    private var pollTimer: Timer?
    /// Whether shared-keychain IPC works from this process. Probed, not
    /// inferred from hasFullAccess — the probe is the ground truth.
    private var ipcAvailable = false
    /// Set when THIS keyboard asked for a transcription; results produced by
    /// the app's own test button are acknowledged but never inserted here.
    private var awaitingResultSince: Date?

    init(controller: KeyboardViewController) {
        self.controller = controller
        bus.observe(Flow.stateNotification) { [weak self] in
            self?.refresh()
        }
    }

    func becameVisible(showsGlobe: Bool) {
        self.showsGlobe = showsGlobe
        ipcAvailable = store.isAvailable
        if ipcAvailable {
            store.keyboardSeen = true
        }
        refresh()
        // Darwin notifications cover the happy path; the poll covers a
        // suspended app, dropped notifications, and heartbeat expiry.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func becameHidden() {
        pollTimer?.invalidate()
        pollTimer = nil
        showingHistory = false
        // Don't leave the app recording into the void if the user dismissed
        // the keyboard mid-dictation.
        if state == .recording {
            send(.cancelSegment)
        }
        awaitingResultSince = nil
    }

    // MARK: user actions

    func micTapped() {
        switch state {
        case .ready:
            send(.startSegment)
            state = .recording  // optimistic; refresh() confirms
        case .recording:
            send(.stopSegment)
            awaitingResultSince = Date()
            state = .transcribing
        default:
            break
        }
    }

    func endSessionTapped() {
        send(.endSession)
        state = .noSession
    }

    /// Tone chip: cycle Formal → Casual → no caps → Excited!.
    func cycleTone() {
        tone = tone.next
        store.tone = tone
        bus.post(Flow.commandNotification)   // nudges the app UI to re-read
    }

    /// Insert a history item at the cursor (tapped from the preview strip).
    func insert(_ result: FlowResult) {
        guard let controller else { return }
        controller.insert(FlowText.smartJoin(before: controller.textBeforeCursor,
                                             insertion: result.text))
        showingHistory = false
        flashInserted()
    }

    func deleteTapped() { controller?.deleteBackwardOnce() }
    func spaceTapped() { controller?.insertSpace() }
    func returnTapped() { controller?.insertNewline() }

    // MARK: state sync

    private func send(_ action: FlowCommand.Action) {
        store.send(action)
        bus.post(Flow.commandNotification)
    }

    private func refresh() {
        guard controller != nil else { return }
        if !ipcAvailable {
            ipcAvailable = store.isAvailable
            if ipcAvailable { store.keyboardSeen = true }
        }
        guard ipcAvailable else {
            state = .needsFullAccess
            return
        }
        tone = store.tone
        historyItems = store.results.filter { !$0.text.isEmpty }.reversed()
        consumeResultIfAny()
        if store.state == .recording {
            if recordingStartedAt == nil { recordingStartedAt = Date() }
        } else {
            recordingStartedAt = nil
        }

        guard store.sessionAlive else {
            state = .noSession
            return
        }
        micLevel = store.micLevel
        switch store.state {
        case .idle:
            state = .noSession
        case .loading:
            state = .loading(store.modelStatus)
        case .ready:
            // Hold the spinner while a result we asked for is still coming.
            state = awaitingResultSince == nil ? .ready : .transcribing
        case .recording:
            state = .recording
        case .transcribing:
            state = .transcribing
        }
    }

    private func consumeResultIfAny() {
        guard let result = store.nextUnconsumedResult() else { return }
        store.lastConsumedResultID = result.id

        guard let since = awaitingResultSince,
              result.finishedAt >= since.timeIntervalSince1970 - 1 else { return }
        awaitingResultSince = nil

        guard !result.text.isEmpty else { return }
        let text = FlowText.smartJoin(before: controller?.textBeforeCursor,
                                      insertion: result.text)
        controller?.insert(text)
        flashInserted()
    }

    private func flashInserted() {
        justInserted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.justInserted = false
        }
    }
}
