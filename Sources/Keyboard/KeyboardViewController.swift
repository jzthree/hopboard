import SwiftUI
import UIKit

/// The keyboard is deliberately dumb: it cannot record (iOS forbids the mic
/// to every keyboard extension), so it renders session state from the App
/// Group, sends commands to the app, and inserts whatever text comes back.
final class KeyboardViewController: UIInputViewController {
    private var model: KeyboardModel!
    private var host: UIHostingController<KeyboardRootView>!
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
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
        if heightConstraint == nil {
            let constraint = view.heightAnchor.constraint(equalToConstant: 254)
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

    /// Extensions cannot call UIApplication.open; the sanctioned-in-practice
    /// route is extensionContext, with the responder-chain openURL: fallback.
    func openMainApp() {
        let url = Flow.startSessionURL
        extensionContext?.open(url) { [weak self] success in
            guard !success else { return }
            DispatchQueue.main.async { self?.openViaResponderChain(url) }
        }
    }

    private func openViaResponderChain(_ url: URL) {
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), !(current is UIInputViewController) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
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
