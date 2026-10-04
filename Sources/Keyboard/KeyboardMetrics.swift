import UIKit

/// How big the keyboard is, per device and orientation.
///
/// Everything here used to be four constants tuned for one phone held
/// upright. A 258pt keyboard in landscape leaves almost nothing of a
/// 390pt-tall screen for the thing you are typing into, and iPad keys
/// sized for a thumb look like a phone screenshot stretched to fill a
/// tablet. Width is the honest signal: the extension cannot ask the host
/// app which way it is held, but it is always told how wide it has been
/// made.
struct KeyboardMetrics: Equatable {
    /// The keys-and-candidates keyboard.
    var typingHeight: CGFloat
    /// The dictation remote — one row and a key strip, never a keyboard.
    var remoteHeight: CGFloat
    /// Headroom above the top row, shared by preview bubbles and the
    /// candidate bar, since an extension cannot paint outside its bounds.
    var topInset: CGFloat
    var rowSpacing: CGFloat
    var keySpacing: CGFloat
    var sideInset: CGFloat
    var bottomInset: CGFloat

    /// A phone turned sideways is wider than any phone is tall.
    static func isLandscapePhone(_ width: CGFloat, _ idiom: UIUserInterfaceIdiom) -> Bool {
        idiom != .pad && width > 500
    }

    static func forWidth(_ width: CGFloat,
                         idiom: UIUserInterfaceIdiom = .phone) -> KeyboardMetrics {
        if idiom == .pad {
            // Full-size keys; the hand is resting, not reaching.
            let wide = width > 900
            return KeyboardMetrics(typingHeight: wide ? 384 : 320,
                                   remoteHeight: wide ? 168 : 150,
                                   topInset: wide ? 62 : 56,
                                   rowSpacing: 14, keySpacing: 10,
                                   sideInset: 6, bottomInset: 8)
        }
        if isLandscapePhone(width, idiom) {
            // Short rows and a thin strip: the screen is mostly keyboard
            // otherwise, and what you are typing into disappears.
            return KeyboardMetrics(typingHeight: 172, remoteHeight: 96,
                                   topInset: 34, rowSpacing: 6, keySpacing: 5,
                                   sideInset: 3, bottomInset: 3)
        }
        return KeyboardMetrics(typingHeight: 258, remoteHeight: 124,
                               topInset: 46, rowSpacing: 10, keySpacing: 6,
                               sideInset: 3, bottomInset: 5)
    }

    func height(typing: Bool) -> CGFloat { typing ? typingHeight : remoteHeight }
}
