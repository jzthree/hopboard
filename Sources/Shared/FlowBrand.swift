import SwiftUI

// One accent for both processes: the keyboard extension has no asset
// catalog, so the brand color lives in code.
enum FlowBrand {
    static let accent = Color(red: 0.29, green: 0.52, blue: 0.85)
}

/// Capsule chrome for pills/chips: Liquid Glass on iOS 26, a tinted
/// capsule below. Pass a tint for colored pills, nil for neutral chips.
struct GlassPill: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint.opacity(0.35)), in: Capsule())
            } else {
                content.glassEffect(.regular, in: Capsule())
            }
        } else {
            content.background(
                Capsule().fill(tint?.opacity(0.15) ?? Color(.secondarySystemFill)))
        }
    }
}

extension View {
    func glassPill(tint: Color? = nil) -> some View {
        modifier(GlassPill(tint: tint))
    }
}
