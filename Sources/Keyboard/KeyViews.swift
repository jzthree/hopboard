import UIKit

/// Keyboard chrome, matched to the system's rather than to the app's: a
/// keyboard that does not look like a keyboard reads as broken, however
/// nice the colours are.
enum KeyPalette {
    static let letter = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.42, alpha: 1) : .white }
    static let control = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1) }
    /// Pressed INVERTS the pair: a letter darkens, a control lightens, so
    /// the moving finger always uncovers contrast rather than losing it.
    static let letterPressed = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.56, alpha: 1) : UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1) }
    static let controlPressed = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.42, alpha: 1) : .white }
    static let popover = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.52, alpha: 1) : .white }
}

final class KeyView: UIView {
    private let cap: KeyCap
    private let label = UILabel()
    private let icon = UIImageView()

    init(cap: KeyCap) {
        self.cap = cap
        super.init(frame: .zero)
        layer.cornerRadius = 5
        layer.cornerCurve = .continuous
        // The 1pt drop under every system key. Cheap only with an explicit
        // path — without one UIKit rasterises the shape every frame.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
        backgroundColor = cap.isControl ? KeyPalette.control : KeyPalette.letter

        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.textColor = .label
        icon.contentMode = .center
        icon.tintColor = .label
        for view in [label, icon] as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
        icon.frame = bounds
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 5).cgPath
    }

    func apply(title: String?, shiftState symbolName: String?) {
        if let symbolName {
            icon.image = UIImage(systemName: symbolName)
            icon.isHidden = false
            label.isHidden = true
        } else {
            icon.isHidden = true
            label.isHidden = false
            label.text = title
            // Letters ride larger than words: "return" has to fit, "q" has
            // to be readable past a thumb.
            let isWord = (title?.count ?? 0) > 2
            label.font = .systemFont(ofSize: isWord ? 16 : 22,
                                     weight: isWord ? .regular : .light)
        }
    }

    func setPressed(_ pressed: Bool) {
        backgroundColor = pressed
            ? (cap.isControl ? KeyPalette.controlPressed : KeyPalette.letterPressed)
            : (cap.isControl ? KeyPalette.control : KeyPalette.letter)
    }
}

/// The bubble over a pressed key. Its whole job is to show the character
/// the finger is covering — without it a keyboard feels like guessing.
final class KeyPreviewView: UIView {
    init(text: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = KeyPalette.popover
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        let label = UILabel()
        label.text = text
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 30, weight: .light)
        label.textColor = .label
        label.frame = bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
}

/// The long-press row: è é ê ë. Slide along it and lift on one.
final class AlternatesView: UIView {
    private let options: [String]
    private var labels: [UILabel] = []
    private var selected = 0

    init(options: [String]) {
        self.options = options
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = KeyPalette.popover
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        labels = options.map { option in
            let label = UILabel()
            label.text = option
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 22, weight: .light)
            label.textColor = .label
            label.layer.cornerRadius = 5
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            addSubview(label)
            return label
        }
        highlight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !labels.isEmpty else { return }
        let width = (bounds.width - 12) / CGFloat(labels.count)
        for (index, label) in labels.enumerated() {
            label.frame = CGRect(x: 6 + CGFloat(index) * width, y: 5,
                                 width: width, height: bounds.height - 10)
        }
    }

    var selectedOption: String? {
        options.indices.contains(selected) ? options[selected] : nil
    }

    /// Pick by horizontal position, clamped — sliding past the end keeps
    /// the last one rather than selecting nothing.
    func selectOption(at point: CGPoint) {
        guard !labels.isEmpty, bounds.width > 12 else { return }
        let width = (bounds.width - 12) / CGFloat(labels.count)
        let index = Int((point.x - 6) / width)
        let clamped = min(max(index, 0), labels.count - 1)
        guard clamped != selected else { return }
        selected = clamped
        highlight()
        KeyFeedback.tap()
    }

    private func highlight() {
        for (index, label) in labels.enumerated() {
            label.backgroundColor = index == selected ? .tintColor : .clear
            label.textColor = index == selected ? .white : .label
        }
    }
}

/// The three slots above the keys: what you typed, what it will become,
/// and one more way out. Tapping the literal is how you refuse a
/// correction — and refusing teaches, so it stops being offered.
final class CandidateBarView: UIView {
    var onPick: ((Autocorrect.Suggestion) -> Void)?
    private var suggestions: [Autocorrect.Suggestion] = []
    private var labels: [UILabel] = []
    private var separators: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func show(_ new: [Autocorrect.Suggestion]) {
        guard new != suggestions else { return }
        suggestions = new
        labels.forEach { $0.removeFromSuperview() }
        separators.forEach { $0.removeFromSuperview() }
        labels = new.map { suggestion in
            let label = UILabel()
            // The literal wears quotes, the way the system marks the word
            // it will NOT keep unless you say so.
            label.text = suggestion.isLiteral ? "\u{201C}\(suggestion.text)\u{201D}" : suggestion.text
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 17,
                                     weight: suggestion.isDefault ? .semibold : .regular)
            label.textColor = .label
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            addSubview(label)
            return label
        }
        separators = (1..<max(new.count, 1)).map { _ in
            let line = UIView()
            line.backgroundColor = UIColor.label.withAlphaComponent(0.18)
            addSubview(line)
            return line
        }
        isHidden = new.isEmpty
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !labels.isEmpty else { return }
        let slot = bounds.width / CGFloat(labels.count)
        for (index, label) in labels.enumerated() {
            label.frame = CGRect(x: CGFloat(index) * slot, y: 0,
                                 width: slot, height: bounds.height)
                .insetBy(dx: 6, dy: 0)
        }
        for (index, line) in separators.enumerated() {
            line.frame = CGRect(x: CGFloat(index + 1) * slot - 0.5,
                                y: bounds.height * 0.22, width: 1,
                                height: bounds.height * 0.56)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, !labels.isEmpty else { return }
        let slot = bounds.width / CGFloat(labels.count)
        // Clamped, not validated away: a tap on this bar that resolves to
        // nothing is the same dead tap the key grid refuses to have.
        let raw = Int(touch.location(in: self).x / slot)
        let index = min(max(raw, 0), suggestions.count - 1)
        onPick?(suggestions[index])
    }
}
