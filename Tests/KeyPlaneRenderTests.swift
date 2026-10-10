import XCTest
import SwiftUI
import UIKit
@testable import HopBoard

/// Renders the real key plane and checks what came out. Layout bugs in
/// keyboard chrome are invisible to logic tests and expensive to find on a
/// device — this repo has already shipped a pill whose tap target was the
/// size of its label. The render is also written to the test bundle's temp
/// directory and its path printed, so it can actually be looked at.
@MainActor
final class KeyPlaneRenderTests: XCTestCase {
    private func makePlane(width: CGFloat = 393,
                           metrics: KeyboardMetrics? = nil) -> KeyPlaneView {
        let m = metrics ?? KeyboardMetrics.forWidth(width, idiom: .phone)
        let plane = KeyPlaneView(frame: CGRect(x: 0, y: 0, width: width,
                                               height: m.typingHeight))
        plane.metricsOverride = m
        plane.seedContext("")
        plane.layoutIfNeeded()
        return plane
    }

    private func render(_ plane: KeyPlaneView, named name: String) throws {
        let renderer = UIGraphicsImageRenderer(bounds: plane.bounds)
        let image = renderer.image { _ in
            plane.drawHierarchy(in: plane.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 4_000, "\(name) rendered almost nothing")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keyplane-\(name).png")
        try? data.write(to: url)
        print("KEYPLANE_SNAPSHOT \(url.path)")
    }

    /// Every shape the keyboard takes, drawn — the numbers for landscape
    /// and iPad are guesses until somebody looks at them.
    func testRendersOnEveryDevice() throws {
        try render(makePlane(), named: "phone-portrait")
        try render(makePlane(width: 852,
                             metrics: .forWidth(852, idiom: .phone)),
                   named: "phone-landscape")
        try render(makePlane(width: 820, metrics: .forWidth(820, idiom: .pad)),
                   named: "pad-portrait")
    }

    func testEveryKeyIsLaidOutInsideThePlane() {
        let plane = makePlane()
        let keyViews = plane.subviews.compactMap { $0 as? KeyView }
        // Four rows: 10 + 9 + 9 + 4.
        XCTAssertEqual(keyViews.count, 32)
        for key in keyViews {
            XCTAssertTrue(plane.bounds.contains(key.frame),
                          "key escapes the plane: \(key.frame)")
            XCTAssertGreaterThanOrEqual(key.frame.minY, plane.topInset - 0.01,
                                        "key sits under the bubble strip")
            // A target smaller than this cannot be hit by a thumb.
            XCTAssertGreaterThanOrEqual(key.frame.height, 30)
            XCTAssertGreaterThanOrEqual(key.frame.width, 24)
        }
    }


}

/// "The touch zone of all buttons should seamlessly cover the entire
/// keyboard space regardless of the visual size of the key." (Jian)
/// Geometry already resolves every point to a nearest key — but only for
/// touches that REACH the plane. A key view that accepts touches of its
/// own would quietly take them out of that scheme, and the gaps around it
/// with them.
@MainActor
final class TouchCoverageTests: XCTestCase {
    func testNoKeyViewEverSwallowsATouch() {
        let plane = KeyPlaneView(frame: CGRect(x: 0, y: 0, width: 393, height: 258))
        plane.seedContext("")
        plane.layoutIfNeeded()

        let keys = plane.subviews.compactMap { $0 as? KeyView }
        XCTAssertFalse(keys.isEmpty)
        for key in keys {
            XCTAssertFalse(key.isUserInteractionEnabled,
                           "a key view can take a touch the plane never sees")
        }

        var unowned: [CGPoint] = []
        var stolen: [CGPoint] = []
        for x in stride(from: CGFloat(0), through: plane.bounds.width, by: 4) {
            for y in stride(from: CGFloat(0), through: plane.bounds.height, by: 4) {
                let point = CGPoint(x: x, y: y)
                let hit = plane.hitTest(point, with: nil)
                if hit == nil { unowned.append(point) }
                if hit is KeyView { stolen.append(point) }
            }
        }
        XCTAssertTrue(unowned.isEmpty, "\(unowned.count) points belong to nothing")
        XCTAssertTrue(stolen.isEmpty, "\(stolen.count) points go to a key view")
    }
}

/// Sweeping the plane proves the plane. It does not prove that the plane
/// FILLS the keyboard — the SwiftUI host in between can inset it, and an
/// inset band reaches no key at all. Jian has reported dead space four
/// times; this tests the whole chain rather than the part I happened to
/// be looking at.
@MainActor
final class HostingCoverageTests: XCTestCase {
    private struct ProbePad: UIViewRepresentable {
        let plane: KeyPlaneView
        func makeUIView(context: Context) -> KeyPlaneView { plane }
        func updateUIView(_ uiView: KeyPlaneView, context: Context) {}
    }

    func testEveryPointOfTheKeyboardReachesTheKeys() {
        let plane = KeyPlaneView(frame: .zero)
        let host = UIHostingController(rootView: ProbePad(plane: plane).ignoresSafeArea())
        host.safeAreaRegions = []
        host.view.insetsLayoutMarginsFromSafeArea = false
        // The home indicator's band, which is what used to be stolen.
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0)
        // In a real window: a detached hosting controller never runs
        // SwiftUI's layout pass, and measuring that would prove nothing.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 258))
        window.rootViewController = host
        window.isHidden = false
        window.layoutIfNeeded()
        plane.seedContext("")
        window.layoutIfNeeded()

        XCTAssertEqual(plane.frame, host.view.bounds,
                       "the keys do not fill the keyboard: \(plane.frame)")

        var unreachable: [CGPoint] = []
        // `to:`, not `through:` — a 258pt view does not contain y = 258,
        // and sweeping the exclusive edge measures the coordinate system
        // rather than the keyboard.
        for x in stride(from: CGFloat(0), to: host.view.bounds.width, by: 3) {
            for y in stride(from: CGFloat(0), to: host.view.bounds.height, by: 3) {
                let point = CGPoint(x: x, y: y)
                let hit = host.view.hitTest(point, with: nil)
                let landed = hit === plane || (hit?.isDescendant(of: plane) ?? false)
                if !landed { unreachable.append(point) }
            }
        }
        XCTAssertTrue(unreachable.isEmpty,
                      "\(unreachable.count) points never reach the keys, "
                      + "first at \(unreachable.first ?? .zero)")
    }
}

/// Dictation ran correctly for days with nothing on screen to show it,
/// because the strip's three tenants were ranked wrong: a chips row left
/// open — one tap on the strip does that — hid the recording UI.
@MainActor
final class StripPriorityTests: XCTestCase {
    private func plane(status: DictationStatus,
                       chips: [StripChipsView.Chip]) -> KeyPlaneView {
        let plane = KeyPlaneView(frame: CGRect(x: 0, y: 0, width: 393, height: 258))
        plane.seedContext("")
        plane.chips = chips
        plane.status = status
        plane.layoutIfNeeded()
        return plane
    }

    private func visibleStrip(_ plane: KeyPlaneView) -> UIView? {
        plane.subviews.first {
            ($0 is DictationStripView || $0 is StripChipsView || $0 is CandidateBarView)
                && !$0.isHidden
        }
    }

    func testRecordingIsVisibleEvenWithTheChipsOpen() {
        let view = visibleStrip(plane(status: DictationStatus(phase: .recording,
                                                              startedAt: Date()),
                                      chips: [.init(title: "EN", symbol: nil),
                                              .init(title: "Formal", symbol: nil)]))
        XCTAssertTrue(view is DictationStripView,
                      "the chips hid the recording UI again")
    }

    func testTheChipsStillShowWhenNothingIsDictating() {
        let view = visibleStrip(plane(status: DictationStatus(),
                                      chips: [.init(title: "EN", symbol: nil)]))
        XCTAssertTrue(view is StripChipsView)
    }

    /// And it must be seen, not merely unhidden.
    func testTheRecordingStripIsOpaque() {
        let plane = plane(status: DictationStatus(phase: .recording, startedAt: Date()),
                          chips: [])
        let strip = plane.subviews.compactMap { $0 as? DictationStripView }.first
        let alpha = strip?.backgroundColor?.cgColor.alpha ?? 0
        XCTAssertEqual(alpha, 1, accuracy: 0.01, "the recording strip is see-through")
        XCTAssertGreaterThan(strip?.frame.height ?? 0, 20)
    }
}

/// Jian: "try to tap between keys to test dead zone too."
///
/// Every previous test here reasons about geometry or hit testing. None
/// of them ever put a finger on a key and checked that something came
/// out. This sweeps the whole surface through the real resolve-and-commit
/// path and records what each tap PRODUCED.
@MainActor
final class SyntheticTapTests: XCTestCase {
    private final class Recorder: KeyPlaneDelegate {
        var inserted: [String] = []
        var deletes = 0
        func keyPlane(_ plane: KeyPlaneView, didInsert text: String) { inserted.append(text) }
        func keyPlaneDidBackspace(_ plane: KeyPlaneView) { deletes += 1 }
        func keyPlaneDidTapReturn(_ plane: KeyPlaneView) { inserted.append("\n") }
        func keyPlaneDidTapDictation(_ plane: KeyPlaneView) {}
        func keyPlaneDidHoldDictation(_ plane: KeyPlaneView) {}
        func keyPlaneDidTapIdleStrip(_ plane: KeyPlaneView) {}
        func keyPlaneStripPrimary(_ plane: KeyPlaneView) {}
        func keyPlaneStripSecondary(_ plane: KeyPlaneView) {}
        func keyPlaneDidPickChip(_ plane: KeyPlaneView, at index: Int) {}
        func keyPlane(_ plane: KeyPlaneView, replaceLast count: Int, with text: String) {}
    }

    func testEveryTapAnywhereProducesAnAction() {
        let recorder = Recorder()
        let plane = KeyPlaneView(frame: CGRect(x: 0, y: 0, width: 393, height: 258))
        plane.delegate = recorder
        plane.seedContext("")
        plane.layoutIfNeeded()

        var dead: [CGPoint] = []
        var gapTaps = 0
        let frames = KeyGeometry.frames(rows: KeyLayout.rows(for: .letters),
                                        in: plane.bounds.size,
                                        metrics: KeyboardMetrics.forWidth(393))
        for x in stride(from: CGFloat(1), to: plane.bounds.width, by: 3) {
            for y in stride(from: CGFloat(1), to: plane.bounds.height, by: 3) {
                let point = CGPoint(x: x, y: y)
                // Is this point in the crack between two keys?
                let inside = frames.contains { row in row.contains { $0.contains(point) } }
                if !inside { gapTaps += 1 }
                if plane.simulateTap(at: point) == nil { dead.append(point) }
            }
        }
        XCTAssertGreaterThan(gapTaps, 200, "the sweep never landed between keys")
        XCTAssertTrue(dead.isEmpty, "\(dead.count) taps produced nothing, first \(dead.first!)")
    }

    /// Specifically the cracks: the midpoint of every gap between two
    /// adjacent keys, and the four edges, must type something.
    func testTheCracksBetweenKeysType() {
        let recorder = Recorder()
        let plane = KeyPlaneView(frame: CGRect(x: 0, y: 0, width: 393, height: 258))
        plane.delegate = recorder
        plane.seedContext("")
        plane.layoutIfNeeded()
        let frames = KeyGeometry.frames(rows: KeyLayout.rows(for: .letters),
                                        in: plane.bounds.size,
                                        metrics: KeyboardMetrics.forWidth(393))
        var tried = 0
        for row in frames {
            for (a, b) in zip(row, row.dropFirst()) {
                let crack = CGPoint(x: (a.maxX + b.minX) / 2, y: a.midY)
                XCTAssertNotNil(plane.simulateTap(at: crack), "dead crack at \(crack)")
                tried += 1
            }
            // And the gap below this row.
            let below = CGPoint(x: row[0].midX, y: row[0].maxY + 4)
            XCTAssertNotNil(plane.simulateTap(at: below), "dead gap under a row")
        }
        XCTAssertGreaterThan(tried, 25)
        XCTAssertFalse(recorder.inserted.isEmpty, "cracks resolved but nothing was typed")
    }
}
