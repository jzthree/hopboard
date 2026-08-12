import Foundation
import UIKit
// NOTE: the keyboard extension links no inference framework at all (not
// even WhisperKit) — every model runs in the app, on the app's memory.

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
    /// "slow" (a long dictation) from "stuck".
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
    /// An insert waiting to be confirmed against the document context.
    private struct Probe {
        let id: UUID?
        /// Folded tail of what we inserted — the only evidence that OUR
        /// text is what landed.
        let tail: String
        /// The context as it read the instant BEFORE we typed. Without it a
        /// field that already ended with our tail confirms itself.
        let before: String?
        let at: Date
        /// The first poll that read as landed. A verdict is only final once
        /// it survives — see holdSeconds.
        var confirmedAt: Date?
    }
    private var insertProbe: Probe?
    /// How long a positive reading must HOLD before the dictation is
    /// retired. A host with its own state (a web form, a React Native or
    /// Flutter field) accepts insertText and then re-renders the text away;
    /// sampling once caught the moment in between and called it delivered.
    private static let holdSeconds: TimeInterval = 0.9
    /// How long to keep looking before calling an insert swallowed.
    private static let verdictSeconds: TimeInterval = 2.5
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
        // A probe can only be settled by reading the document we typed
        // into. Once the keyboard leaves, the answer is unknowable — drop it
        // without a verdict rather than blaming the next field we land in.
        // The dictation stays unconsumed, so it returns as an Insert pill.
        insertProbe = nil
    }

    // MARK: user actions

    func micTapped() {
        switch state {
        case .ready:
            // An unclaimed dictation is NOT retired here. Marking it
            // consumed on the way into a recording meant one stray tap —
            // and the mic owns the whole row, so strays happen — silently
            // put the text out of reach of the pill. It doesn't linger
            // either: once this dictation produces a result, that result
            // becomes the newest and updatePendingResult stops offering the
            // old one. Discard the recording instead and the offer returns,
            // which is what someone who mis-tapped wanted.
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
        guard insertProbe == nil else { return }
        showingHistory = false
        // Claim it too: a history item the user just placed shouldn't then
        // reappear as an unclaimed Insert pill.
        attemptInsert(result.text, claiming: result.id == store.results.last?.id ? result.id : nil)
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
        // Settle any pending insert first: its verdict decides whether the
        // result counts as delivered or goes back on offer as a pill.
        verifyInsertIfNeeded()
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
        // Never mark a result consumed unless it actually landed in the
        // document. The old code claimed it up front and returned early on
        // two paths (a result older than this wait; an insert the host
        // ignored) — both left the text alive only in history with nothing
        // on the keyboard to offer it.
        guard insertProbe == nil, let result = store.nextUnconsumedResult() else { return }
        // Auto-insert is only ever for a dictation THIS keyboard asked for;
        // anything else waits behind an explicit tap on the Insert pill.
        guard let since = awaitingResultSince,
              result.finishedAt >= since.timeIntervalSince1970 - 1 else { return }
        guard !result.text.isEmpty else {
            // Nothing was said: acknowledge it so the spinner is released.
            store.lastConsumedResultID = result.id
            awaitingResultSince = nil
            return
        }
        // It arrived; stop waiting either way. Success is decided by the
        // probe below — failure leaves it unconsumed, so the pill offers it.
        awaitingResultSince = nil
        attemptInsert(result.text, claiming: result.id)
    }

    /// The Insert pill's tap: insert at the cursor and retire the result.
    func insertPending() {
        guard let pending = pendingResult, insertProbe == nil else { return }
        attemptInsert(pending.text, claiming: pending.id)
    }

    /// Insert, then VERIFY on a later tick. insertText is a one-way message
    /// to the host app: with no focused field it is a silent no-op, and the
    /// document context does not update synchronously either — so the check
    /// cannot be made inline.
    private func attemptInsert(_ text: String, claiming id: UUID?) {
        guard let controller else { return }
        let before = controller.textBeforeCursor
        let joined = FlowText.smartJoin(before: before, insertion: text)
        guard !joined.isEmpty else { return }
        insertProbe = Probe(id: id, tail: FlowText.foldTail(joined),
                            before: before, at: Date())
        controller.insert(joined)
    }

    private func verifyInsertIfNeeded() {
        guard var probe = insertProbe, let controller else { return }
        let elapsed = Date().timeIntervalSince(probe.at)
        // The host applies the edit and reports the new context on its own
        // schedule; poll for a while before concluding anything.
        guard elapsed >= 0.3 else { return }
        let verdict = self.verdict(for: probe, controller)
        guard verdict.isDelivered else {
            // Seen once and now gone: the host took the text and undid it.
            // That is a failure, and an immediate one — no point waiting
            // out the clock on a document we already watched change back.
            if probe.confirmedAt != nil {
                settle(probe, as: .reverted)
            } else if elapsed >= Self.verdictSeconds {
                settle(probe, as: verdict)
            }
            return
        }
        // Positive, but not yet final: it has to still be true a beat later.
        guard let since = probe.confirmedAt else {
            probe.confirmedAt = Date()
            insertProbe = probe
            return
        }
        guard Date().timeIntervalSince(since) >= Self.holdSeconds else { return }
        settle(probe, as: verdict)
    }

    /// What the document says about our insert right now. Comparing the
    /// context before and after was wrong — documentContextBeforeInput
    /// arrives asynchronously, so any "it changed" test reports success for
    /// an insert that never happened. The honest check is that the context
    /// now ENDS with what we inserted, and grew to do it.
    private func verdict(for probe: Probe,
                         _ controller: KeyboardViewController) -> InsertVerdict {
        FlowText.insertVerdict(contextBefore: probe.before,
                               contextAfter: controller.textBeforeCursor,
                               insertedTail: probe.tail,
                               isSecure: controller.documentIsSecure,
                               hasText: controller.documentHasText)
    }

    /// Close out a probe: record what happened either way, and retire the
    /// dictation only on a delivery. A failure leaves the result unconsumed,
    /// so the pill stays and the text is one tap from the cursor.
    private func settle(_ probe: Probe, as verdict: InsertVerdict) {
        insertProbe = nil
        if let id = probe.id {
            store.record(FlowDelivery(id: id, verdict: verdict,
                                      at: Date().timeIntervalSince1970))
            // Wake the app so its history shows the verdict without waiting
            // for the next command.
            bus.post(Flow.commandNotification)
            guard verdict.isDelivered else { return }
            store.lastConsumedResultID = id
            pendingResult = nil
        }
        guard verdict.isDelivered else { return }
        flashInserted()
    }

    private func updatePendingResult() {
        // Any unclaimed dictation is offered, whether or not we were the
        // one waiting for it — that is the promise: text never exists only
        // in history. Hold off while an insert is being verified so the
        // pill doesn't flicker between attempt and verdict.
        guard insertProbe == nil else { return }
        guard let last = store.results.last, !last.text.isEmpty,
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
