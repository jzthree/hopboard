import UIKit

/// One tap's worth of feedback, Apple-keyboard style: a light haptic plus
/// the system key click (which respects the user's Sounds settings).
/// A fresh, prepared generator per tap — the shared-static generator went
/// silent in the extension; attaching to the keyboard's view (iOS 17.5+)
/// is the reliable form.
enum KeyFeedback {
    static weak var hostView: UIView?

    static func tap() {
        let generator: UIImpactFeedbackGenerator
        if #available(iOS 17.5, *), let hostView {
            generator = UIImpactFeedbackGenerator(style: .light, view: hostView)
        } else {
            generator = UIImpactFeedbackGenerator(style: .light)
        }
        generator.prepare()
        generator.impactOccurred()
        UIDevice.current.playInputClick()
    }
}
