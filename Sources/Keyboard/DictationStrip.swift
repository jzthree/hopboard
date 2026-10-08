import UIKit

/// What dictation is doing, as the keyboard needs to draw it.
struct DictationStatus: Equatable {
    enum Phase: Equatable { case none, recording, transcribing, pending }
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
