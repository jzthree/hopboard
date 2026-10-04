import UIKit

@MainActor
protocol KeyPlaneDelegate: AnyObject {
    func keyPlane(_ plane: KeyPlaneView, didInsert text: String)
    func keyPlaneDidBackspace(_ plane: KeyPlaneView)
    func keyPlaneDidTapReturn(_ plane: KeyPlaneView)
    func keyPlaneDidTapDictation(_ plane: KeyPlaneView)
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

    /// Headroom above the top row, so a preview bubble has somewhere to go
    /// — a keyboard extension cannot draw outside its own bounds, so unlike
    /// the system keyboard the top row's bubble has to live INSIDE. The
    /// candidate bar shares this strip; bubbles overlay it, as they do on
    /// the system keyboard.
    var topInset: CGFloat = 46 { didSet { setNeedsLayout() } }

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
        init(row: Int, col: Int) { self.row = row; self.col = col }
    }
    private var touching: [ObjectIdentifier: Touching] = [:]
    private var repeatTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = true
        rebuildKeys()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    // MARK: context

    func seedContext(_ text: String?) {
        tail = String((text ?? "").suffix(TypingEngine.tailLimit))
        applyAutoShift()
    }

    // MARK: layout

    override func layoutSubviews() {
        super.layoutSubviews()
        frames = KeyGeometry.frames(rows: rows, in: bounds.size, topInset: topInset)
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
        for (rowIndex, rowFrames) in frames.enumerated() {
            for (colIndex, frame) in rowFrames.enumerated() {
                // Generous vertically: the gap between rows belongs to the
                // nearer row rather than to nothing.
                if frame.insetBy(dx: 0, dy: -5).contains(point) {
                    return (rowIndex, colIndex)
                }
            }
        }
        return nil
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
        guard commit else { return }
        if let chosen {
            insert(chosen)
            return
        }
        commitKey(cap(state))
    }

    private func commitKey(_ cap: KeyCap) {
        switch cap.action {
        case .text(let character):
            insert(isShifted ? character.uppercased() : character)
        case .shift:
            toggleShift()
        case .backspace:
            // Already fired on touch-down, and repeated while held.
            break
        case .layer(let layer):
            switchTo(layer)
        case .space:
            if TypingEngine.doubleSpacePeriod(after: tail) {
                delegate?.keyPlaneDidBackspace(self)
                tail = TypingEngine.deletingLast(from: tail)
                insert(". ")
            } else {
                insert(" ")
            }
        case .newline:
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
        // A layer switched to for one symbol returns to letters, the way
        // the system does after you type a number's worth of punctuation.
        applyAutoShift()
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
        delegate?.keyPlaneDidBackspace(self)
        tail = TypingEngine.deletingLast(from: tail)
        applyAutoShift()
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
