import Foundation
import UIKit
// NOTE: this file must never import llama — the keyboard extension links
// neither WhisperKit nor llama.cpp; all inference lives in the app.

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
    @Published private(set) var language: String = "auto"
    /// Recent non-empty dictations, newest first — browsable from the
    /// keyboard so a dictation that landed nowhere (focus lost, keyboard
    /// dismissed mid-transcribe) is recoverable with a preview.
    @Published private(set) var historyItems: [FlowResult] = []
    @Published var showingHistory = false
    /// A finished dictation that could NOT be auto-inserted (keyboard was
    /// away, wait timed out, or it came from the app). Lingers as an
    /// "Insert" pill until tapped or superseded — never silently eaten.
    @Published private(set) var pendingResult: FlowResult?
    /// The correction pad: a minimal QWERTY for typing "yes" instead of
    /// dictating it. Temporary by design — no autocorrect, no prose.
    @Published private(set) var typingMode = false
    /// When the current recording started — drives the live timer that
    /// makes the recording state unmissable.
    @Published private(set) var recordingStartedAt: Date?
    /// When transcribing began — a visible elapsed timer distinguishes
    /// "slow" (Gemma grinding) from "stuck".
    @Published private(set) var transcribingStartedAt: Date?

    private weak var controller: KeyboardViewController?
    /// The UIKit globe key needs the controller for handleInputModeList.
    var globeController: KeyboardViewController? { controller }
    private let store = FlowStore()
    private let bus = DarwinBus()
    private var pollTimer: Timer?
    /// A tap's expected state, displayed for at most 2 s while the command
    /// travels to the app. After that (or once the store confirms), the
    /// display always follows the store — the engine's true state.
    private var optimistic: (state: UIState, at: Date)?
    /// Whether shared-keychain IPC works from this process. Probed, not
    /// inferred from hasFullAccess — the probe is the ground truth.
    private var ipcAvailable = false
    /// Set when THIS keyboard asked for a transcription; results produced by
    /// the app's own test button are acknowledged but never inserted here.
    /// PERSISTED (extension defaults): the keyboard gets hidden and reshown
    /// mid-transcription all the time (focus changes, app hops), and a new
    /// controller instance that forgot it was waiting silently swallowed
    /// the result — the "stuck at Transcribing, text only in history" bug.
    private var awaitingResultSince: Date? {
        get { UserDefaults.standard.object(forKey: "kb.awaitingSince") as? Date }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: "kb.awaitingSince")
            } else {
                UserDefaults.standard.removeObject(forKey: "kb.awaitingSince")
            }
        }
    }

    init(controller: KeyboardViewController) {
        self.controller = controller
        bus.observe(Flow.stateNotification) { [weak self] in
            self?.refresh()
        }
    }

    func becameVisible(showsGlobe: Bool) {
        self.showsGlobe = showsGlobe
        controller?.setKeyboardHeight(typingMode ? 216 : 124)
        // NO keychain traffic on the launch path: the keyboard service's
        // watchdog kills slow cold starts (worst right after an app update,
        // when everything is uncached) and iOS then skips to the next
        // keyboard. First frame renders from defaults; the probe and state
        // sync run right after.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.ipcAvailable = self.store.isAvailable
            if self.ipcAvailable { self.store.keyboardSeen = true }
            self.refresh()
        }
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
        typingMode = false   // the pad is temporary by design
        // Don't leave the app recording into the void if the user dismissed
        // the keyboard mid-dictation. A transcription already in flight is
        // NOT cancelled and awaitingResultSince deliberately survives —
        // the result inserts when the keyboard next appears (45 s bound).
        if state == .recording {
            send(.cancelSegment)
        }
    }

    // MARK: user actions

    func micTapped() {
        switch state {
        case .ready:
            // Starting a new dictation supersedes an unclaimed old one.
            if let pending = pendingResult {
                store.lastConsumedResultID = pending.id
                pendingResult = nil
            }
            send(.startSegment)
            optimistic = (.recording, Date())
            state = .recording
        case .recording:
            send(.stopSegment)
            awaitingResultSince = Date()   // insert bookkeeping, not display
            optimistic = (.transcribing, Date())
            state = .transcribing
        default:
            break
        }
    }

    /// Throw away what's being said instead of transcribing it — misspoken
    /// dictation shouldn't force an insert-then-delete. Nothing is awaited,
    /// so no result can arrive to insert.
    func discardRecording() {
        guard state == .recording else { return }
        send(.cancelSegment)
        awaitingResultSince = nil
        recordingStartedAt = nil
        optimistic = (.ready, Date())
        state = .ready
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

    /// Language chip: cycle the user's pinned keyboard languages (config →
    /// Keyboard languages). Critical for single-locale engines (Apple):
    /// dictating English through the Chinese model — or the other way
    /// round — produces phonetic soup, so the language must be visible and
    /// switchable without leaving the keyboard. Auto is skipped while the
    /// engine has no detection.
    func cycleLanguage() {
        var cycle = store.favoriteLanguages
        if !store.autoLanguageAllowed {
            cycle.removeAll { $0 == "auto" }
        }
        if cycle.isEmpty { cycle = ["en"] }
        let index = cycle.firstIndex(of: language).map { ($0 + 1) % cycle.count } ?? 0
        language = cycle[index]
        store.language = language
        bus.post(Flow.commandNotification)
    }

    var languageLabel: String {
        switch language {
        case "auto": "Auto"
        case "en": "EN"
        case "zh": "中文"
        default: language.uppercased()
        }
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

    func setTyping(_ on: Bool) {
        typingMode = on
        showingHistory = false
        controller?.setKeyboardHeight(on ? 216 : 124)
    }

    func typeText(_ text: String) {
        controller?.insert(text)
    }

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
        let storedLanguage = store.language
        language = storedLanguage.isEmpty ? "auto" : storedLanguage
        historyItems = store.results.filter { !$0.text.isEmpty }.reversed()
        // Consume BEFORE the escape hatches: a slow transcription (>10 s —
        // routine right after an install while the ANE cache rebuilds) used
        // to hit the escape and the consume in the same tick, clearing the
        // waiting marker first and swallowing the result into history.
        consumeResultIfAny()
        // Escape hatches for a stranded wait: if the app is back to ready
        // with nothing for us within 10 s — or 45 s outright — stop waiting.
        if let since = awaitingResultSince {
            let waited = Date().timeIntervalSince(since)
            if waited > 45 || (store.state == .ready && waited > 10) {
                awaitingResultSince = nil
            }
        }
        updatePendingResult()
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

        // The store IS the engine's true state; render it.
        let truth: UIState
        switch store.state {
        case .idle: truth = .noSession
        case .loading: truth = .loading(store.modelStatus)
        case .ready: truth = .ready
        case .recording: truth = .recording
        case .transcribing: truth = .transcribing
        }

        // A just-tapped command may still be in flight — bridge with the
        // expected state for at most 2 s, then defer to the truth.
        if let optimistic {
            let bridgeValid = Date().timeIntervalSince(optimistic.at) < 2
                && ((optimistic.state == .recording && truth == .ready)
                    || (optimistic.state == .transcribing && truth == .recording))
            if bridgeValid {
                state = optimistic.state
                trackTranscribing()
                return
            }
            self.optimistic = nil
        }
        state = truth
        trackTranscribing()
    }

    private func trackTranscribing() {
        if state == .transcribing {
            if transcribingStartedAt == nil { transcribingStartedAt = Date() }
        } else {
            transcribingStartedAt = nil
        }
    }

    private func consumeResultIfAny() {
        // Only ever claim a result while we're actually waiting for one —
        // marking results consumed while not waiting is how dictations got
        // silently eaten. Results we didn't ask for just sit in history.
        guard let since = awaitingResultSince,
              let result = store.nextUnconsumedResult() else { return }
        store.lastConsumedResultID = result.id
        guard result.finishedAt >= since.timeIntervalSince1970 - 1 else { return }
        awaitingResultSince = nil

        guard !result.text.isEmpty else { return }
        let text = FlowText.smartJoin(before: controller?.textBeforeCursor,
                                      insertion: result.text)
        controller?.insert(text)
        flashInserted()
    }

    /// The Insert pill's tap: insert at the cursor and retire the result.
    func insertPending() {
        guard let pending = pendingResult else { return }
        store.lastConsumedResultID = pending.id
        pendingResult = nil
        controller?.insert(FlowText.smartJoin(before: controller?.textBeforeCursor,
                                              insertion: pending.text))
        flashInserted()
    }

    private func updatePendingResult() {
        guard awaitingResultSince == nil,
              let last = store.results.last, !last.text.isEmpty,
              last.id != store.lastConsumedResultID else {
            if pendingResult != nil { pendingResult = nil }
            return
        }
        pendingResult = last
    }

    private func flashInserted() {
        justInserted = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.justInserted = false
        }
    }
}
