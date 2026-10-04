import XCTest
import UIKit
@testable import HopBoard

/// Renders the real key plane and checks what came out. Layout bugs in
/// keyboard chrome are invisible to logic tests and expensive to find on a
/// device — this repo has already shipped a pill whose tap target was the
/// size of its label. The render is also written to the test bundle's temp
/// directory and its path printed, so it can actually be looked at.
@MainActor
final class KeyPlaneRenderTests: XCTestCase {
    private func makePlane() -> KeyPlaneView {
        let plane = KeyPlaneView(frame: CGRect(x: 0, y: 0, width: 393, height: 258))
        plane.seedContext("")
        plane.layoutIfNeeded()
        return plane
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

    func testRenderIsNotBlank() throws {
        let plane = makePlane()
        let renderer = UIGraphicsImageRenderer(bounds: plane.bounds)
        let image = renderer.image { _ in
            plane.drawHierarchy(in: plane.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        // A plane that drew nothing still produces a PNG; one that drew 32
        // keys produces a much bigger one.
        XCTAssertGreaterThan(data.count, 4_000, "the plane rendered almost nothing")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keyplane.png")
        try? data.write(to: url)
        print("KEYPLANE_SNAPSHOT \(url.path)")
    }
}
