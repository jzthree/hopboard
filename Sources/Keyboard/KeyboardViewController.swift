import SwiftUI
import UIKit

/// The keyboard is deliberately dumb: it cannot record (iOS forbids the mic
/// to every keyboard extension), so it renders session state from the App
/// Group, sends commands to the app, and inserts whatever text comes back.
/// System keyboard clicks require the input view itself to opt in.
final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

final class KeyboardViewController: UIInputViewController {
    private var model: KeyboardModel!
    private var host: UIHostingController<KeyboardRootView>!
    private var heightConstraint: NSLayoutConstraint?

    override func loadView() {
        view = ClickingInputView(frame: .zero, inputViewStyle: .keyboard)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyFeedback.hostView = view
        model = KeyboardModel(controller: self)
        host = UIHostingController(rootView: KeyboardRootView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Custom keyboards choose their own height; Apple sets no minimum.
        // 124 pt ≈ 57% of the ~216 pt system keyboard: one mic/status row
        // and one key row — a remote control, not a letter grid. The
        // correction pad temporarily grows it back to ~216.
        if heightConstraint == nil {
            let constraint = view.heightAnchor.constraint(
                equalToConstant: KeyboardMetrics.forScreen(
                    width: screenSize.width, height: screenSize.height,
                    idiom: traitCollection.userInterfaceIdiom).remoteHeight)
            constraint.priority = .init(999)
            constraint.isActive = true
            heightConstraint = constraint
        }
        model.becameVisible(showsGlobe: needsInputModeSwitchKey)
    }

    override func viewWillDisappear(_ animated: Bool) {
        model.becameHidden()
        super.viewWillDisappear(animated)
    }

    // MARK: services for the model

    func insert(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    var textBeforeCursor: String? {
        textDocumentProxy.documentContextBeforeInput
    }

    /// Secure fields never report context, so a successful insert there is
    /// invisible to a before/after comparison — this distinguishes them
    /// from having no focused field at all.
    var documentHasText: Bool { textDocumentProxy.hasText }

    /// Password fields: the proxy withholds the document context entirely,
    /// so an insert there can never be confirmed by reading it back.
    var documentIsSecure: Bool { textDocumentProxy.isSecureTextEntry ?? false }

    func deleteBackwardOnce() {
        textDocumentProxy.deleteBackward()
    }

    func insertNewline() {
        textDocumentProxy.insertText("\n")
    }

    func insertSpace() {
        textDocumentProxy.insertText(" ")
    }

    var keyboardHasFullAccess: Bool { hasFullAccess }

    /// The height the current device and orientation want. Only the
    /// controller knows how wide it has been made, and width is the only
    /// signal an extension gets about which way the phone is held.
    /// The screen the keyboard is actually on. Both numbers matter: width
    /// alone cannot tell a phone on its side from a foldable opened up.
    private var screenSize: CGSize {
        let screen = view.window?.screen ?? UIScreen.main
        return screen.bounds.size
    }

    func applyHeight(typing: Bool) {
        let size = screenSize
        let width = view.bounds.width > 0 ? view.bounds.width : size.width
        let metrics = KeyboardMetrics.forScreen(width: width, height: size.height,
                                                idiom: traitCollection.userInterfaceIdiom)
        heightConstraint?.constant = metrics.height(typing: typing)
    }

    /// Rotation changes the answer, and nothing else asks again.
    override func viewWillTransition(to size: CGSize,
                                     with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // The screen's own height, not the keyboard's: a fold or a rotation
        // changes which shape this is, and the transition size is the view.
        let metrics = KeyboardMetrics.forScreen(
            width: size.width, height: screenSize.height,
            idiom: traitCollection.userInterfaceIdiom)
        heightConstraint?.constant = metrics.height(typing: model.typingMode)
    }
}

/// The required input-mode switch key. UIKit needs the raw control events
/// (long-press shows the keyboard picker), so this stays a UIButton.
struct GlobeKey: UIViewRepresentable {
    weak var controller: KeyboardViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        if let controller {
            button.addTarget(controller,
                             action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                             for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
