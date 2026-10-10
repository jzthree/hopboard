import SwiftUI
import UIKit

/// The real key plane, hosted inside the app, so it can be poked.
///
/// The keyboard extension cannot be exercised in a simulator: enabling a
/// custom keyboard takes Settings taps nothing here can perform, and the
/// shared keychain group needs entitlements the simulator refuses. That
/// blind spot is why "there is still dead space between the keys" has
/// survived every test I have written — all of them reason about geometry
/// and hit testing, none of them has ever put a finger on a key.
///
/// This runs the SAME KeyPlaneView, through the SAME SwiftUI hosting, and
/// writes down what every touch produced.
struct KeyboardBench: View {
    @State private var typed = ""
    @State private var log: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(typed.isEmpty ? "(nothing typed yet)" : typed)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: .infinity)
            Text(log.suffix(6).joined(separator: "\n"))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            BenchPad(onInsert: { text in
                typed += text
                log.append("insert \(text.debugDescription)")
            }, onDelete: {
                typed = String(typed.dropLast())
                log.append("delete")
            })
            .frame(height: KeyboardMetrics.forWidth(UIScreen.main.bounds.width).typingHeight)
        }
        .navigationTitle("Keyboard bench")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BenchPad: UIViewRepresentable {
    let onInsert: (String) -> Void
    let onDelete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> KeyPlaneView {
        let plane = KeyPlaneView(frame: .zero)
        plane.delegate = context.coordinator
        plane.showsTouchLog = true
        plane.seedContext("")
        return plane
    }

    func updateUIView(_ plane: KeyPlaneView, context: Context) {}

    @MainActor
    final class Coordinator: KeyPlaneDelegate {
        private let bench: BenchPad
        init(_ bench: BenchPad) { self.bench = bench }

        func keyPlane(_ plane: KeyPlaneView, didInsert text: String) { bench.onInsert(text) }
        func keyPlaneDidBackspace(_ plane: KeyPlaneView) { bench.onDelete() }
        func keyPlaneDidTapReturn(_ plane: KeyPlaneView) { bench.onInsert("\n") }
        func keyPlaneDidTapDictation(_ plane: KeyPlaneView) {}
        func keyPlaneDidHoldDictation(_ plane: KeyPlaneView) {}
        func keyPlaneDidTapIdleStrip(_ plane: KeyPlaneView) {}
        func keyPlaneStripPrimary(_ plane: KeyPlaneView) {}
        func keyPlaneStripSecondary(_ plane: KeyPlaneView) {}
        func keyPlaneDidPickChip(_ plane: KeyPlaneView, at index: Int) {}
        func keyPlane(_ plane: KeyPlaneView, replaceLast count: Int, with text: String) {
            bench.onInsert(text)
        }
    }
}
