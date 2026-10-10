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
    /// A finished dictation that could NOT be auto-inserted (keyboard was
    /// away, wait timed out, or it came from the app). Lingers as an
    /// "Insert" pill until tapped or superseded — never silently eaten.
    @Published private(set) var pendingResult: FlowResult?
    /// Whether the keyboard is showing keys rather than the mic. PERSISTED
    /// (extension defaults), because the keyboard is torn down and rebuilt
    /// constantly — focus changes, app hops, the screen locking — and a
    /// keyboard that dumps you back on the dictation row every time it
    /// reappears cannot be anyone's default. It stopped being a temporary
    /// correction pad when it grew autocorrect.
    /// What the strip above the keys should be saying. Everything the
    /// dictation row used to show has to fit here now, including the two
    /// things the keyboard cannot fix by itself.
    var stripStatus: DictationStatus {
        guard ipcAvailable else {
            // Two very different failures wore the same label. If iOS says
            // Full Access is already granted, telling someone to go and
            // grant it is worse than useless — they have, and the real
            // fault is the app link itself.
            guard controller?.keyboardHasFullAccess == true else {
                return DictationStatus(phase: .message("Tap to turn on Full Access"))
            }
            // The build number has to come from the EXTENSION itself and
            // not through the store, because the store is the thing that
            // is broken. iOS keeps old .appex binaries alive across app
            // reinstalls, so "the fix did not work" and "the fix is not
            // running" look identical from the outside, and this is the
            // only place that can tell them apart right now.
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            return DictationStatus(
                phase: .message("kb \(build) · unreachable · \(store.probeDiagnosis)"))
        }
        switch state {
        case .recording:
            return DictationStatus(phase: .recording, startedAt: recordingStartedAt,
                                   level: micLevel, canRetranscribe: canRetranscribe)
        case .transcribing:
            return DictationStatus(phase: .transcribing, startedAt: transcribingStartedAt,
                                   canRetranscribe: canRetranscribe)
        case .loading(let status):
            return DictationStatus(phase: .message(status.isEmpty ? "Preparing model…" : status))
        case .noSession:
            return DictationStatus(phase: .message("Tap to start a HopBoard session"))
        default:
            guard pendingResult != nil else { return DictationStatus() }
            return DictationStatus(phase: .pending, canRetranscribe: canRetranscribe)
        }
    }

    /// The controls the dictation row used to carry as chips. Opened by
    /// holding the mic key; picking one closes them again.
    @Published private(set) var chipsOpen = false

    var stripChips: [StripChipsView.Chip] {
        guard chipsOpen else { return [] }
        var chips: [StripChipsView.Chip] = [
            .init(title: languageLabel, symbol: nil),
            .init(title: tone.shortLabel, symbol: nil),
        ]
        if canRetranscribe { chips.append(.init(title: "Again", symbol: nil)) }
        chips.append(.init(title: "End", symbol: nil))
        chips.append(.init(title: "Settings", symbol: nil))
        return chips
    }

    func toggleChips() { chipsOpen.toggle() }

    func pickChip(at index: Int) {
        let chips = stripChips
        guard chips.indices.contains(index) else { return }
        switch chips[index].title {
        case languageLabel: cycleLanguage()
        case "Again": retranscribeLast()
        case "End": endSessionTapped()
        case "Settings":
            chipsOpen = false
            openSettings?()
        default: cycleTone()
        }
        if chips[index].title == "Again" || chips[index].title == "End" {
            chipsOpen = false
        }
    }

    /// Opening the app is the one thing a keyboard extension cannot do for
    /// itself — iOS 18 killed every selector route to UIApplication, so
    /// SwiftUI's openURL action is handed in from the view layer.
    var openSettings: (() -> Void)?
    var openApp: (() -> Void)?
    var openFullAccess: (() -> Void)?

    /// The strip's main action, whatever it currently reads as.
    func stripPrimary() {
        switch state {
        case .recording: micTapped()
        case .noSession: openApp?()
        case .loading: openApp?()
        default:
            // The strip is telling you Full Access is off; tapping it
            // should go and turn it on, not just open the app and leave
            // you to find the setting.
            guard ipcAvailable else { openFullAccess?(); return }
            insertPending()
        }
    }

    func stripSecondary() {
        switch state {
        case .recording: discardRecording()
        default: retranscribeLast()
        }
    }
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
    private var lastPollWanted = false
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
    /// How long a dictation the keyboard asked for may still insert ITSELF.
    /// Past this it is still offered — as a pill — but it must not type
    /// itself into whatever app happens to be open by then: a wait now
    /// survives the keyboard being hidden, and a phone can stay locked for
    /// an hour with a finished transcript waiting behind it.
    private static let waitBudget: TimeInterval = 45

    /// Whether shared-keychain IPC works from this process. Probed, not
    /// inferred from hasFullAccess — the probe is the ground truth.
    private var ipcAvailable = false
    /// Whether the keyboard is actually on screen. Darwin notifications
    /// drive refresh() whether it is or not — becameHidden only stops the
    /// poll timer — so without this a result arriving while the keyboard is
    /// away gets typed into a document nobody is focused on, which spends
    /// the one auto-insert that dictation gets.
    private var isVisible = false
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
        isVisible = true
        self.showsGlobe = showsGlobe
        controller?.applyHeight()
        // NO keychain traffic on the launch path: the keyboard service's
        // watchdog kills slow cold starts (worst right after an app update,
        // when everything is uncached) and iOS then skips to the next
        // keyboard. First frame renders from defaults; the probe and state
        // sync run right after.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.ipcAvailable = self.store.isAvailable
            self.syncPollTimer()
            if self.ipcAvailable {
                self.store.keyboardSeen = true
                // Stamp which binary is actually running. Written only on a
                // change — this is a keychain round trip, not a counter.
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                if self.store.keyboardBuild != build { self.store.keyboardBuild = build }
            }
            self.refresh()
        }
        syncPollTimer()
    }

    /// The 0.35s poll exists for dictation: a suspended app, a dropped
    /// notification, an expired heartbeat. While the KEYS are up it buys
    /// nothing and costs a great deal — every tick is six keychain round
    /// trips and up to four JSON decodes of the result list, synchronously,
    /// on the same main thread that has to deliver the next touch and draw
    /// the next frame. Three times a second, underneath someone typing.
    /// Darwin notifications still arrive, so nothing is missed; the timer
    /// is only the backstop, and a backstop has no business running while
    /// its subject is idle.
    private func syncPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
        defer { lastPollWanted = pollTimer != nil }
        // The keys are always up now, so the poll follows the WORK: a
        // dictation in flight is the one thing happening that no keystroke
        // will report. Typing alone needs no keychain traffic at all.
        let dictating = state == .recording || state == .transcribing
            || pendingResult != nil
        // And while IPC is DOWN. The probe can fail for a moment at launch
        // — the extension is still being granted Full Access, the device
        // was locked a beat ago — and refresh is the only thing that ever
        // retries it. With the poll asleep and no Darwin notification
        // coming (the app cannot send one to a keyboard it cannot reach),
        // one unlucky first probe used to mean the keyboard sat on "turn
        // on Full Access" forever, with nothing able to change its mind.
        guard isVisible, dictating || !ipcAvailable else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func becameHidden() {
        isVisible = false
        pollTimer?.invalidate()
        pollTimer = nil
        // A recording in progress is ENDED, not thrown away. The keyboard
        // goes away for reasons that have nothing to do with wanting the
        // dictation gone — above all the screen locking mid-sentence, which
        // used to discard everything said up to that moment. Speech becomes
        // text either way; the text comes back as an Insert pill, or types
        // itself if you return quickly. Discarding stays where it belongs:
        // behind the Discard button, which is a decision, not an accident.
        if state == .recording {
            send(.stopSegment)
            awaitingResultSince = Date()
            state = .transcribing
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
        syncPollTimer()
        send(.cancelSegment)
        awaitingResultSince = nil
        recordingStartedAt = nil
        optimistic = (.ready, Date())
        state = .ready
    }

    func endSessionTapped() {
        send(.endSession)
        state = .noSession
        syncPollTimer()
    }

    /// The mic key on the keyboard. Switching to a dictation screen and
    /// then pressing record is two taps to say one thing, and the first one
    /// carries no meaning the second does not — so when there is a session
    /// to speak into, this IS the record button, and nothing leaves the
    /// screen while you use it.
    ///
    /// With no session there is nowhere for the words to go, so the tap
    /// opens the app instead — the strip above has already been saying so.
    func dictationKeyTapped() {
        // The poll sleeps while you type, so the cached state may be old.
        // Read it once, here, where the answer decides something.
        refresh()
        guard store.sessionAlive, state == .ready || state == .recording else {
            openApp?()
            return
        }
        micTapped()
        syncPollTimer()
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
        // Claim it too: a history item the user just placed shouldn't then
        // reappear as an unclaimed Insert pill.
        attemptInsert(result.text, claiming: result.id == store.results.last?.id ? result.id : nil)
    }

    func deleteTapped() { controller?.deleteBackwardOnce() }
    func spaceTapped() { controller?.insertSpace() }
    /// Return while a dictation is running ENDS it rather than typing a
    /// newline. Mid-recording a newline is never what was wanted, and the
    /// key is already under the thumb — reaching back up to the mic surface
    /// to stop is the awkward part of a one-handed dictation. Stopping is
    /// all it does: the transcript still arrives and inserts on its own,
    /// and nothing is submitted on the user's behalf.
    func returnTapped() {
        if state == .recording {
            micTapped()
            return
        }
        controller?.insertNewline()
    }

    /// What precedes the cursor right now, for seeding the pad's shift
    /// state. Nil whenever the host has not reported yet — the pad then
    /// starts capitalised, which is right far more often than not.
    var documentTail: String? { controller?.textBeforeCursor }

    /// Swap the last `count` characters for `text` — how an autocorrect
    /// lands, since a keyboard can only type and delete.
    func replaceLast(_ count: Int, with text: String) {
        for _ in 0..<count { controller?.deleteBackwardOnce() }
        controller?.insert(text)
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
            if ipcAvailable {
                store.keyboardSeen = true
                // Recovered: the retry poll has done its job and can stop.
                syncPollTimer()
            }
        }
        guard ipcAvailable else {
            state = .needsFullAccess
            return
        }
        tone = store.tone
        canRetranscribe = store.canRetranscribe
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
        // Only while we are on screen. Typing into a document the user is
        // not looking at goes nowhere, and the attempt is not free: it
        // settles the probe, leaves the result unconsumed, and the dictation
        // comes back as a pill for text that could have inserted itself a
        // moment later. Holding the wait instead means it lands the instant
        // the keyboard returns — which is why the same dictation sometimes
        // inserts and sometimes has to be tapped in.
        if isVisible {
            consumeResultIfAny()
            // Escape hatches for a stranded wait: if the app is back to
            // ready with nothing for us within 10 s — or 45 s outright —
            // stop waiting. Checked only while on screen, so a wait can no
            // longer expire unseen, and the consume above always gets first
            // refusal on the tick where we return.
            if let since = awaitingResultSince {
                let waited = Date().timeIntervalSince(since)
                if waited > Self.waitBudget || (store.state == .ready && waited > 10) {
                    awaitingResultSince = nil
                }
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
              Date().timeIntervalSince(since) <= Self.waitBudget,
              result.finishedAt >= since.timeIntervalSince1970 - 1 else { return }
        guard !result.text.isEmpty else {
            // Nothing was said: acknowledge it so the spinner is released,
            // and give the keys back — there is nothing to offer.
            store.lastConsumedResultID = result.id
            awaitingResultSince = nil
            syncPollTimer()
            return
        }
        // It arrived; stop waiting either way. Success is decided by the
        // probe below — failure leaves it unconsumed, so the pill offers it.
        awaitingResultSince = nil
        attemptInsert(result.text, claiming: result.id)
    }

    /// Whether the app still has the audio to decode again.
    @Published private(set) var canRetranscribe = false

    /// Ask for the last dictation to be decoded again — Whisper sometimes
    /// hands back something mangled that a second, warmer pass gets right,
    /// and re-speaking it is the expensive way to ask. The new text arrives
    /// as a normal result, so it lands on the pill rather than inserting
    /// itself behind whatever is already at the cursor.
    func retranscribeLast() {
        guard canRetranscribe else { return }
        send(.retranscribe)
        optimistic = (.transcribing, Date())
        state = .transcribing
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
            if probe.confirmedAt != nil {
                // Seen once and now gone. Only a document we can STILL read,
                // now ending in something else, is evidence the host undid
                // the edit. A host that has stopped reporting anything has
                // told us nothing — and a terminal does exactly that, since
                // SwiftTerm clears the composition buffer that backs the
                // keyboard's context while the text sits on screen. Reading
                // that as a revert is what stopped auto-insert into hop-ios;
                // absence of evidence is not evidence of reversion.
                settle(probe, as: verdict == .unreadable ? .landed : .reverted)
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
        syncPollTimer()
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
