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

    /// Classification from the SHAPE of the screen, never from a device
    /// name. Width alone was wrong the moment a folding phone existed: a
    /// phone on its side and a foldable opened up are both wide, and only
    /// one of them wants a squashed keyboard. The short screen is the
    /// landscape one; a wide AND tall screen is tablet-shaped whatever the
    /// idiom reports, which is also how a device that ships after this code
    /// gets sensible keys without anyone teaching it the device.
    static func isShortScreen(_ height: CGFloat) -> Bool { height < 500 }
    static func isTabletShaped(width: CGFloat, height: CGFloat,
                               idiom: UIUserInterfaceIdiom) -> Bool {
        !isShortScreen(height) && (idiom == .pad || width >= 700)
    }

    static func forScreen(width: CGFloat, height: CGFloat,
                          idiom: UIUserInterfaceIdiom = .phone) -> KeyboardMetrics {
        var metrics: KeyboardMetrics
        if isShortScreen(height) {
            // Short rows and a thin strip: the screen is mostly keyboard
            // otherwise, and what you are typing into disappears.
            metrics = KeyboardMetrics(typingHeight: 172, remoteHeight: 96,
                                      topInset: 34, rowSpacing: 6, keySpacing: 5,
                                      sideInset: 3, bottomInset: 3)
        } else if isTabletShaped(width: width, height: height, idiom: idiom) {
            // Full-size keys; the hand is resting, not reaching.
            let wide = width > 900
            metrics = KeyboardMetrics(typingHeight: wide ? 384 : 320,
                                      remoteHeight: wide ? 168 : 150,
                                      topInset: wide ? 62 : 56,
                                      rowSpacing: 14, keySpacing: 10,
                                      sideInset: 6, bottomInset: 8)
        } else {
            metrics = KeyboardMetrics(typingHeight: 258, remoteHeight: 124,
                                      topInset: 46, rowSpacing: 10, keySpacing: 6,
                                      sideInset: 3, bottomInset: 5)
        }
        // Whatever the shape, the keyboard never eats half the screen. This
        // is the backstop for a form factor nobody here has held: get the
        // class wrong and the keys are the wrong size, but the thing being
        // typed into is still visible.
        if height > 0 {
            let ceiling = height * 0.48
            if metrics.typingHeight > ceiling {
                let scale = ceiling / metrics.typingHeight
                metrics.typingHeight = ceiling
                metrics.topInset = max(metrics.topInset * scale, 26)
                metrics.remoteHeight = min(metrics.remoteHeight, height * 0.3)
            }
        }
        return metrics
    }

    /// Convenience for callers that only know a width — it assumes the
    /// screen is at least as tall as a phone's, which is true of every
    /// upright device and of none held sideways.
    static func forWidth(_ width: CGFloat,
                         idiom: UIUserInterfaceIdiom = .phone) -> KeyboardMetrics {
        forScreen(width: width, height: width > 500 && idiom != .pad ? 400 : 900,
                  idiom: idiom)
    }

    func height(typing: Bool) -> CGFloat { typing ? typingHeight : remoteHeight }
}
