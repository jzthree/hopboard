import UIKit

/// What dictation is doing, as the keyboard needs to draw it.
struct DictationStatus: Equatable {
    enum Phase: Equatable {
        case none, recording, transcribing, pending
        /// Something the keyboard cannot fix by itself — no session yet, or
        /// Full Access off. The strip says it and the tap opens the app,
        /// because there is no dictation screen left to say it on.
        case message(String)
    }
    var phase: Phase = .none
    var startedAt: Date?
    var level: Float = 0
    var canRetranscribe = false
}

/// The strip above the keys, when there is dictation to show instead of
/// candidates.
///
/// This is what replaced swapping the whole keyboard out for a dictation
/// screen. The keys never leave: you tap the mic, this strip takes over
/// the row the candidates were using, and when the words land it hands the
/// row back. Nothing moves, nothing resizes, and there is no mode to be
/// in or get out of — which was the point.
final class DictationStripView: UIView {
    var onPrimary: (() -> Void)?    // stop, or insert
    var onSecondary: (() -> Void)?  // discard, or transcribe again

    private let dot = UIView()
    private let title = UILabel()
    private let secondary = UILabel()
    private var ticker: Timer?
    private var status = DictationStatus()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        // Opaque. Transparent chrome over a transparent key plane is how
        // "is it even running?" happens — and the recording state is the
        // one thing in this keyboard that has to be unmissable.
        backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.16, alpha: 1) : UIColor(white: 0.90, alpha: 1) }
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 4
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .label
        secondary.font = .systemFont(ofSize: 14, weight: .medium)
        secondary.textAlignment = .center
        secondary.textColor = .secondaryLabel
        secondary.layer.cornerRadius = 11
        secondary.layer.cornerCurve = .continuous
        secondary.clipsToBounds = true
        secondary.backgroundColor = UIColor.label.withAlphaComponent(0.1)
        for view in [dot, title, secondary] as [UIView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    deinit { ticker?.invalidate() }

    func show(_ new: DictationStatus) {
        let phaseChanged = new.phase != status.phase
        status = new
        isHidden = new.phase == .none
        guard !isHidden else {
            ticker?.invalidate(); ticker = nil
            return
        }
        // Transcribing has no action, so the strip stops intercepting and
        // the keys underneath get the touch back. A region that is visible
        // but inert is still dead space.
        isUserInteractionEnabled = new.phase != .transcribing
        if phaseChanged {
            ticker?.invalidate()
            ticker = nil
            if new.phase == .recording || new.phase == .transcribing {
                // Seconds only; the label is the proof it is still alive.
                ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
                    [weak self] _ in MainActor.assumeIsolated { self?.render() }
                }
            }
        }
        render()
    }

    private func render() {
        dot.isHidden = status.phase != .recording
        switch status.phase {
        case .none:
            break
        case .recording:
            title.text = "Recording \(elapsed)  ·  tap to stop"
            title.textColor = .systemRed
            secondary.text = " Discard "
            secondary.isHidden = false
        case .transcribing:
            title.text = "Transcribing \(elapsed)…"
            title.textColor = .secondaryLabel
            secondary.isHidden = true
        case .message(let text):
            title.text = text
            title.textColor = .secondaryLabel
            secondary.isHidden = true
        case .pending:
            title.text = "Tap to insert"
            title.textColor = .label
            secondary.text = status.canRetranscribe ? " Again " : nil
            secondary.isHidden = !status.canRetranscribe
        }
        setNeedsLayout()
    }

    private var elapsed: String {
        guard let startedAt = status.startedAt else { return "" }
        return "\(Int(Date().timeIntervalSince(startedAt)))s"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 10
        var right = bounds.width - inset
        if !secondary.isHidden {
            let width = max(secondary.intrinsicContentSize.width + 16, 64)
            secondary.frame = CGRect(x: right - width, y: (bounds.height - 22) / 2,
                                     width: width, height: 22)
            right -= width + 10
        }
        var left = inset
        if !dot.isHidden {
            dot.frame = CGRect(x: left, y: (bounds.height - 8) / 2, width: 8, height: 8)
            left += 14
        }
        title.frame = CGRect(x: left, y: 0, width: max(right - left, 0), height: bounds.height)
    }

    /// The whole strip is the primary action; only the trailing pill is
    /// the secondary one. Same rule as everywhere else here — a tap that
    /// lands anywhere does something.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, status.phase != .transcribing else { return }
        let point = touch.location(in: self)
        if !secondary.isHidden, point.x >= secondary.frame.minX - 6 {
            onSecondary?()
        } else {
            onPrimary?()
        }
    }
}

/// The strip's other job: the handful of controls that used to live as
/// chips on a dictation row that no longer exists. Held open by the mic
/// key, closed by picking something.
final class StripChipsView: UIView {
    struct Chip: Equatable {
        let title: String
        let symbol: String?
    }

    var onPick: ((Int) -> Void)?
    private var chips: [Chip] = []
    private var labels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func show(_ new: [Chip]) {
        guard new != chips else { return }
        chips = new
        labels.forEach { $0.removeFromSuperview() }
        labels = new.map { chip in
            let label = UILabel()
            label.text = chip.title
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.textAlignment = .center
            label.textColor = .label
            label.backgroundColor = UIColor.label.withAlphaComponent(0.1)
            label.layer.cornerRadius = 11
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            addSubview(label)
            return label
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !labels.isEmpty else { return }
        let gap: CGFloat = 6
        let total = bounds.width - 20 - gap * CGFloat(labels.count - 1)
        let width = total / CGFloat(labels.count)
        for (index, label) in labels.enumerated() {
            label.frame = CGRect(x: 10 + CGFloat(index) * (width + gap),
                                 y: (bounds.height - 24) / 2, width: width, height: 24)
        }
    }

    /// Clamped, like everything else here: a tap in a gap picks a chip.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, !labels.isEmpty else { return }
        let slot = bounds.width / CGFloat(labels.count)
        let index = min(max(Int(touch.location(in: self).x / slot), 0), labels.count - 1)
        onPick?(index)
    }
}
