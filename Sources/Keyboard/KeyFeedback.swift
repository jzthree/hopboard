import UIKit

/// One tap's worth of feedback, Apple-keyboard style: a light haptic plus
/// the system key click (which respects the user's Sounds settings).
///
/// The generator is built ONCE and kept warm. Allocating and preparing one
/// per keystroke — which is what this used to do — spins the haptic engine
/// up from cold on every letter, on the main thread, in the middle of the
/// touch handler. Attaching it to the keyboard's own view (iOS 17.5+) is
/// what makes it fire at all inside an extension; a shared static one with
/// no view went silent.
@MainActor
enum KeyFeedback {
    static weak var hostView: UIView? {
        didSet { generator = nil }
    }
    private static var generator: UIImpactFeedbackGenerator?

    static func tap() {
        if generator == nil {
            if #available(iOS 17.5, *), let hostView {
                generator = UIImpactFeedbackGenerator(style: .light, view: hostView)
            } else {
                generator = UIImpactFeedbackGenerator(style: .light)
            }
            generator?.prepare()
        }
        generator?.impactOccurred()
        // Re-arm for the next key rather than letting the engine idle down.
        generator?.prepare()
        UIDevice.current.playInputClick()
    }
}
