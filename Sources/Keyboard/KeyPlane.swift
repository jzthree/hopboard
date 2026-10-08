import UIKit

@MainActor
protocol KeyPlaneDelegate: AnyObject {
    func keyPlane(_ plane: KeyPlaneView, didInsert text: String)
    func keyPlaneDidBackspace(_ plane: KeyPlaneView)
    func keyPlaneDidTapReturn(_ plane: KeyPlaneView)
    func keyPlaneDidTapDictation(_ plane: KeyPlaneView)
    /// Hold the mic key: go to the dictation row itself, where language,
    /// tone, history and settings live.
    func keyPlaneDidHoldDictation(_ plane: KeyPlaneView)
    /// Swap the word just typed for its correction: delete that many
    /// characters, then insert.
    func keyPlane(_ plane: KeyPlaneView, replaceLast count: Int, with text: String)
}

/// One view owning every touch on the key grid.
///
/// A Button per key — which is what this replaces — cannot do the three
/// things that separate a keyboard from a grid of buttons. It has no
/// preview bubble, so the finger covers the only evidence of what was hit.
/// It cancels when the finger slides off, where the system commits whatever
/// key you LIFT over, which is how a near-miss gets corrected without
/// looking. And it serialises: the second thumb landing before the first
/// lifts is rollover, the thing fast typing is made of, and independent
/// gesture recognisers fight over it. All three need one view tracking
/// every UITouch itself.
final class KeyPlaneView: UIView {
    weak var delegate: KeyPlaneDelegate?

    /// Everything about the plane's size is DERIVED from its own width, so
    /// a rotation or an iPad re-lays it out with nobody pushing a value in.
    /// Set only by tests, which can render at an iPad's width but cannot
    /// change a detached view's idiom.
    var metricsOverride: KeyboardMetrics?
    var metrics: KeyboardMetrics {
        metricsOverride ?? {
            let screen = (window?.screen ?? UIScreen.main).bounds.size
            return KeyboardMetrics.forScreen(width: bounds.width, height: screen.height,
                                             idiom: traitCollection.userInterfaceIdiom)
        }()
    }
    /// Headroom above the top row: an extension cannot draw outside its own
    /// bounds, so unlike the system keyboard the top row's preview bubble
    /// has to live INSIDE. The candidate bar shares the strip.
    var topInset: CGFloat { metrics.topInset }

    private var keyLayer: KeyLayer = .letters
    private var rows: [KeyRow] = KeyLayout.rows(for: .letters)
    private var keyViews: [[KeyView]] = []
    private var frames: [[CGRect]] = []

    private var isShifted = true
    private var isCapsLocked = false
    private var lastShiftTap = Date.distantPast

    /// What this pad has typed, so shift and the double-space period decide
    /// from something synchronous. Seeded from the host when the pad opens.
    private(set) var tail = ""

    private final class Touching {
        var row: Int
        var col: Int
        var preview: KeyPreviewView?
        var alternates: AlternatesView?
        var longPress: Timer?
        /// A hold already did the key's work; lifting must not do it again.
        var consumed = false
        init(row: Int, col: Int) { self.row = row; self.col = col }
    }
    private var touching: [ObjectIdentifier: Touching] = [:]
    private var repeatTimer: Timer?

    private let autocorrect = Autocorrect()
    /// The correction that just happened, and the separator typed after it.
    /// Backspace while this is live UNDOES the correction instead of
    /// deleting a character — the universal way out, and the one that
    /// needs no aiming at a three-slot bar. Any other key closes the
    /// window, exactly as the system keyboard's does.
    private var revert: (original: String, applied: String, trailing: String)?
    private var revertArming = false
    private let candidates = CandidateBarView()
    /// UITextChecker's guesses() is the expensive call on this path; don't
    /// re-ask it for a word that has not changed.
    private var lastCandidateWord: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = true
        addSubview(candidates)
        candidates.onPick = { [weak self] suggestion in self?.pick(suggestion) }
        rebuildKeys()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    // MARK: context

    func seedContext(_ text: String?) {
        tail = String((text ?? "").suffix(TypingEngine.tailLimit))
        applyAutoShift()
        refreshCandidates()
    }

    private func refreshCandidates() {
        let word = TypingEngine.currentWord(in: tail)
        guard word != lastCandidateWord else { return }
        lastCandidateWord = word
        candidates.show(autocorrect.suggestions(for: word))
    }

    /// A tapped slot. The literal is a refusal, and a refusal is a lesson:
    /// the word joins the kept list and stops being questioned.
    private func pick(_ suggestion: Autocorrect.Suggestion) {
        let word = TypingEngine.currentWord(in: tail)
        guard !word.isEmpty else { return }
        KeyFeedback.tap()
        if suggestion.isLiteral {
            autocorrect.keep(word)
        } else {
            delegate?.keyPlane(self, replaceLast: word.count, with: suggestion.text)
            tail = TypingEngine.replacingCurrentWord(in: tail, with: suggestion.text)
        }
        lastCandidateWord = nil
        refreshCandidates()
    }

    /// Apply the pending correction, if any, at the moment the word ends.
    private func applyPendingCorrection() {
        let word = TypingEngine.currentWord(in: tail)
        guard let fix = autocorrect.correction(for: word) else { return }
        delegate?.keyPlane(self, replaceLast: word.count, with: fix)
        tail = TypingEngine.replacingCurrentWord(in: tail, with: fix)
        revert = (original: word, applied: fix, trailing: "")
        revertArming = true
    }

    /// Undo the correction and LEARN from it. Reaching for backspace is
    /// already the user saying "that was wrong"; making them say it twice,
    /// once per occurrence, is how a keyboard becomes an argument.
    private func revertLastCorrection() -> Bool {
        guard let revert else { return false }
        let removed = revert.applied.count + revert.trailing.count
        let restored = revert.original + revert.trailing
        delegate?.keyPlane(self, replaceLast: removed, with: restored)
        tail = String(tail.dropLast(removed)) + restored
        autocorrect.keep(revert.original)
        self.revert = nil
        lastCandidateWord = nil
        applyAutoShift()
        refreshCandidates()
        return true
    }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        candidates.frame = CGRect(x: 0, y: 0, width: bounds.width,
                                  height: max(topInset - 8, 0))
        frames = KeyGeometry.frames(rows: rows, in: bounds.size, metrics: metrics)
        for (rowIndex, row) in keyViews.enumerated() {
            for (colIndex, view) in row.enumerated() {
                guard rowIndex < frames.count, colIndex < frames[rowIndex].count else { continue }
                view.frame = frames[rowIndex][colIndex]
            }
        }
    }

    private func rebuildKeys() {
        keyViews.flatMap { $0 }.forEach { $0.removeFromSuperview() }
        keyViews = rows.map { row in
            row.keys.map { cap in
                let view = KeyView(cap: cap)
                addSubview(view)
                return view
            }
        }
        refreshTitles()
        setNeedsLayout()
    }

    private func refreshTitles() {
        for (rowIndex, row) in keyViews.enumerated() {
            for (colIndex, view) in row.enumerated() {
                let cap = rows[rowIndex].keys[colIndex]
                view.apply(title: cap.title(shifted: isShifted),
                           shiftState: shiftSymbol(for: cap))
            }
        }
    }

    private func shiftSymbol(for cap: KeyCap) -> String? {
        guard cap.action == .shift else { return cap.symbolName }
        if isCapsLocked { return "capslock.fill" }
        return isShifted ? "shift.fill" : "shift"
    }

    private func switchTo(_ layer: KeyLayer) {
        keyLayer = layer
        rows = KeyLayout.rows(for: layer)
        if layer != .letters { isCapsLocked = false }
        rebuildKeys()
    }

    // MARK: touches

    private func keyIndex(at point: CGPoint) -> (row: Int, col: Int)? {
        KeyGeometry.index(at: CGPoint(x: point.x, y: point.y - metrics.touchRise),
                          in: frames)
    }

    private func cap(_ state: Touching) -> KeyCap { rows[state.row].keys[state.col] }
    private func view(_ state: Touching) -> KeyView { keyViews[state.row][state.col] }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let index = keyIndex(at: touch.location(in: self)) else { continue }
            let state = Touching(row: index.row, col: index.col)
            touching[ObjectIdentifier(touch)] = state
            KeyFeedback.tap()
            highlight(state, on: true)
            if cap(state).action == .backspace { startBackspaceRepeat() }
            armLongPress(state)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = touching[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)
            if let alternates = state.alternates {
                alternates.selectOption(at: convert(point, to: alternates))
                continue
            }
            guard let index = keyIndex(at: point),
                  index.row != state.row || index.col != state.col else { continue }
            // Slide-to-correct: the press moves to the key under the finger.
            highlight(state, on: false)
            state.longPress?.invalidate()
            if cap(state).action == .backspace { stopBackspaceRepeat() }
            state.row = index.row
            state.col = index.col
            highlight(state, on: true)
            armLongPress(state)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = touching.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            finish(state, commit: true)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let state = touching.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            finish(state, commit: false)
        }
    }

    private func finish(_ state: Touching, commit: Bool) {
        state.longPress?.invalidate()
        highlight(state, on: false)
        let chosen = state.alternates?.selectedOption
        state.alternates?.removeFromSuperview()
        state.alternates = nil
        if cap(state).action == .backspace { stopBackspaceRepeat() }
        guard commit, !state.consumed else { return }
        if let chosen {
            insert(chosen)
            return
        }
        commitKey(cap(state))
    }

    private func commitKey(_ cap: KeyCap) {
        switch cap.action {
        case .text(let character):
            // Punctuation ends a word, and the end of a word is the only
            // moment a correction can still be applied.
            if TypingEngine.endsWord(character) { applyPendingCorrection() }
            insert(isShifted ? character.uppercased() : character)
        case .shift:
            toggleShift()
        case .backspace:
            // Already fired on touch-down, and repeated while held.
            break
        case .layer(let layer):
            switchTo(layer)
        case .space:
            applyPendingCorrection()
            if TypingEngine.doubleSpacePeriod(after: tail) {
                delegate?.keyPlaneDidBackspace(self)
                tail = TypingEngine.deletingLast(from: tail)
                insert(". ")
            } else {
                insert(" ")
            }
        case .newline:
            applyPendingCorrection()
            delegate?.keyPlaneDidTapReturn(self)
            tail = TypingEngine.appending("\n", to: tail)
            applyAutoShift()
        case .dictation:
            delegate?.keyPlaneDidTapDictation(self)
        }
    }

    private func insert(_ text: String) {
        delegate?.keyPlane(self, didInsert: text)
        tail = TypingEngine.appending(text, to: tail)
        if revertArming {
            // The separator that triggered the correction — undoing has to
            // take it back too, or the cursor lands mid-word.
            revert?.trailing = text
            revertArming = false
        } else {
            revert = nil
        }
        applyAutoShift()
        refreshCandidates()
    }

    private func applyAutoShift() {
        guard !isCapsLocked else { return }
        let wanted = TypingEngine.shouldCapitalize(after: tail)
        guard wanted != isShifted else { return }
        isShifted = wanted
        refreshTitles()
    }

    private func toggleShift() {
        let now = Date()
        if !isCapsLocked, now.timeIntervalSince(lastShiftTap) < 0.35 {
            isCapsLocked = true
            isShifted = true
        } else if isCapsLocked {
            isCapsLocked = false
            isShifted = false
        } else {
            isShifted.toggle()
        }
        lastShiftTap = now
        refreshTitles()
    }

    // MARK: backspace repeat

    private func startBackspaceRepeat() {
        // The first backspace after a correction undoes it rather than
        // deleting, and does not start repeating — holding delete from
        // there would eat the word you just got back.
        if revertLastCorrection() {
            KeyFeedback.tap()
            return
        }
        delegate?.keyPlaneDidBackspace(self)
        tail = TypingEngine.deletingLast(from: tail)
        applyAutoShift()
        refreshCandidates()
        repeatTimer?.invalidate()
        // Hold-to-repeat, then faster — the system's two-stage feel.
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                // Scheduled timers fire on the main run loop; say so, since
                // the closure itself carries no isolation.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.delegate?.keyPlaneDidBackspace(self)
                    self.tail = TypingEngine.deletingLast(from: self.tail)
                    self.applyAutoShift()
                    self.refreshCandidates()
                }
            }
        }
    }

    private func stopBackspaceRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // MARK: previews and alternates

    private func highlight(_ state: Touching, on: Bool) {
        let key = view(state)
        key.setPressed(on)
        if on, cap(state).showsPreview {
            let preview = KeyPreviewView(text: cap(state).title(shifted: isShifted) ?? "")
            preview.frame = previewFrame(over: key.frame)
            addSubview(preview)
            state.preview = preview
        } else {
            state.preview?.removeFromSuperview()
            state.preview = nil
        }
    }

    private func previewFrame(over key: CGRect) -> CGRect {
        let width = max(key.width + 18, 44)
        let height = key.height + 16
        var frame = CGRect(x: key.midX - width / 2, y: key.minY - height - 4,
                           width: width, height: height)
        // Keep it inside: an extension cannot paint over the host app.
        frame.origin.x = min(max(2, frame.origin.x), bounds.width - width - 2)
        frame.origin.y = max(2, frame.origin.y)
        return frame
    }

    private func armLongPress(_ state: Touching) {
        state.longPress?.invalidate()
        // The mic key's hold is a destination, not a character: tapping it
        // now starts dictating straight away, so holding is the only way
        // left to REACH the dictation row — where language, tone, history
        // and transcribe-again live. Without this they are unreachable
        // from the keys.
        if cap(state).action == .dictation {
            state.longPress = Timer.scheduledTimer(withTimeInterval: 0.45,
                                                   repeats: false) { [weak self, weak state] _ in
                MainActor.assumeIsolated {
                    guard let self, let state else { return }
                    state.consumed = true
                    self.highlight(state, on: false)
                    KeyFeedback.tap()
                    self.delegate?.keyPlaneDidHoldDictation(self)
                }
            }
            return
        }
        let options = cap(state).alternates
        guard !options.isEmpty else { return }
        state.longPress = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) {
            [weak self, weak state] _ in
            guard let self, let state else { return }
            let base = self.cap(state).title(shifted: self.isShifted) ?? ""
            let shown = ([base] + options).map { self.isShifted ? $0.uppercased() : $0 }
            state.preview?.removeFromSuperview()
            state.preview = nil
            let view = AlternatesView(options: shown)
            view.frame = self.alternatesFrame(over: self.view(state).frame, count: shown.count)
            self.addSubview(view)
            state.alternates = view
            KeyFeedback.tap()
        }
    }

    private func alternatesFrame(over key: CGRect, count: Int) -> CGRect {
        let width = min(CGFloat(count) * 42 + 12, bounds.width - 8)
        let height = key.height + 14
        var frame = CGRect(x: key.midX - width / 2, y: key.minY - height - 4,
                           width: width, height: height)
        frame.origin.x = min(max(4, frame.origin.x), bounds.width - width - 4)
        frame.origin.y = max(2, frame.origin.y)
        return frame
    }
}
