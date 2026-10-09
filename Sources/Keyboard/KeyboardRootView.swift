import SwiftUI

/// The whole keyboard. There is no second screen any more.
///
/// HopBoard used to open on a dictation remote and keep a QWERTY pad
/// behind an abc key, which meant every sentence cost a mode change in
/// each direction and the thing most people want from a keyboard — keys —
/// was the hidden one. The keys are the keyboard now. Dictation is the
/// mic key plus the strip above them: tap, speak, tap, the words arrive,
/// and nothing ever moves or swaps out.
struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel
    /// iOS 18 killed every selector route from an extension to
    /// UIApplication; SwiftUI's own action is the only way left to open
    /// the app, so the view hands it to the model.
    @Environment(\.openURL) private var openURL

    var body: some View {
        TypePad(model: model)
            .tint(FlowBrand.accent)
            .onAppear {
                model.openApp = { openURL(Flow.startSessionURL) }
                model.openSettings = { openURL(Flow.settingsURL) }
            }
    }
}

/// The keys, in UIKit, because preview bubbles, slide-to-correct and
/// two-thumb rollover all need one view tracking every touch. See
/// KeyPlaneView.
struct TypePad: UIViewRepresentable {
    let model: KeyboardModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> KeyPlaneView {
        let plane = KeyPlaneView(frame: .zero)
        plane.delegate = context.coordinator
        plane.showsGlobe = model.showsGlobe
        plane.seedContext(model.documentTail)
        return plane
    }

    func updateUIView(_ plane: KeyPlaneView, context: Context) {
        plane.showsGlobe = model.showsGlobe
        plane.status = model.stripStatus
        plane.chips = model.stripChips
    }

    @MainActor
    final class Coordinator: KeyPlaneDelegate {
        private let model: KeyboardModel
        init(model: KeyboardModel) { self.model = model }

        func keyPlane(_ plane: KeyPlaneView, didInsert text: String) {
            model.typeText(text)
        }
        func keyPlaneDidBackspace(_ plane: KeyPlaneView) { model.deleteTapped() }
        func keyPlaneDidTapReturn(_ plane: KeyPlaneView) { model.returnTapped() }
        func keyPlaneDidTapDictation(_ plane: KeyPlaneView) { model.dictationKeyTapped() }
        func keyPlaneDidHoldDictation(_ plane: KeyPlaneView) { model.toggleChips() }
        func keyPlaneStripPrimary(_ plane: KeyPlaneView) { model.stripPrimary() }
        func keyPlaneStripSecondary(_ plane: KeyPlaneView) { model.stripSecondary() }
        func keyPlaneDidPickChip(_ plane: KeyPlaneView, at index: Int) {
            model.pickChip(at: index)
        }
        func keyPlane(_ plane: KeyPlaneView, replaceLast count: Int, with text: String) {
            model.replaceLast(count, with: text)
        }
        func keyPlaneGlobeButton(_ plane: KeyPlaneView) -> UIView? {
            model.makeGlobeButton()
        }
    }
}
