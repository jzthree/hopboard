import XCTest
@testable import HopBoard

final class TypingEngineTests: XCTestCase {
    func testCapitalizesAtSentenceStarts() {
        XCTAssertTrue(TypingEngine.shouldCapitalize(after: ""))
        XCTAssertTrue(TypingEngine.shouldCapitalize(after: "Done. "))
        XCTAssertTrue(TypingEngine.shouldCapitalize(after: "Really?  "))
        XCTAssertTrue(TypingEngine.shouldCapitalize(after: "Stop!\n"))
        XCTAssertTrue(TypingEngine.shouldCapitalize(after: "好。 "))
    }

    func testDoesNotCapitalizeMidSentence() {
        XCTAssertFalse(TypingEngine.shouldCapitalize(after: "the "))
        XCTAssertFalse(TypingEngine.shouldCapitalize(after: "the"))
        // A decimal is not a sentence end.
        XCTAssertFalse(TypingEngine.shouldCapitalize(after: "3.5"))
    }

    func testDoubleSpaceBecomesAPeriod() {
        XCTAssertTrue(TypingEngine.doubleSpacePeriod(after: "done "))
        XCTAssertTrue(TypingEngine.doubleSpacePeriod(after: "chapter 2 "))
        // Not on an empty field, not twice, and not after a real period —
        // each of those would produce " ." or "..".
        XCTAssertFalse(TypingEngine.doubleSpacePeriod(after: " "))
        XCTAssertFalse(TypingEngine.doubleSpacePeriod(after: "done  "))
        XCTAssertFalse(TypingEngine.doubleSpacePeriod(after: "done. "))
        XCTAssertFalse(TypingEngine.doubleSpacePeriod(after: "done"))
    }

    func testTailStaysBounded() {
        var tail = ""
        for _ in 0..<200 { tail = TypingEngine.appending("abc", to: tail) }
        XCTAssertEqual(tail.count, TypingEngine.tailLimit)
        XCTAssertEqual(TypingEngine.deletingLast(from: "ab"), "a")
        XCTAssertEqual(TypingEngine.deletingLast(from: ""), "")
    }
}

final class KeyLayoutTests: XCTestCase {
    func testEveryLayerIsAWholeKeyboard() {
        for layer in [KeyLayer.letters, .numbers, .symbols] {
            let rows = KeyLayout.rows(for: layer)
            XCTAssertEqual(rows.count, 4, "\(layer) should have four rows")
            let actions = rows.flatMap { $0.keys.map(\.action) }
            XCTAssertTrue(actions.contains(.space), "\(layer) needs a space bar")
            XCTAssertTrue(actions.contains(.newline), "\(layer) needs return")
            XCTAssertTrue(actions.contains(.backspace), "\(layer) needs delete")
            XCTAssertTrue(actions.contains(.dictation),
                          "\(layer) must offer the way back to the mic")
        }
        XCTAssertEqual(KeyLayout.rows(for: .letters)[0].keys.count, 10)
    }

    /// Accents are the difference between a pad that can write French or
    /// Spanish and one that cannot. They are reachable only on long press,
    /// so a missing entry is silently unreachable.
    func testVowelsCarryAccents() {
        for vowel in ["a", "e", "i", "o", "u"] {
            XCTAssertFalse(KeyLayout.alternates[vowel, default: []].isEmpty,
                           "\(vowel) needs long-press accents")
        }
    }
}

final class KeyGeometryTests: XCTestCase {
    private let size = CGSize(width: 393, height: 258)

    func testKeysFillTheWidthWithoutOverlapping() {
        for layer in [KeyLayer.letters, .numbers, .symbols] {
            let rows = KeyLayout.rows(for: layer)
            let frames = KeyGeometry.frames(rows: rows, in: size, topInset: 46)
            XCTAssertEqual(frames.count, rows.count)
            for (index, row) in frames.enumerated() {
                XCTAssertFalse(row.isEmpty)
                // Inside the bounds, on both edges.
                XCTAssertGreaterThanOrEqual(row.first!.minX, 0)
                XCTAssertLessThanOrEqual(row.last!.maxX, size.width + 0.01)
                // Reaches the far edge unless the row is deliberately inset.
                if rows[index].trailingPad == 0 {
                    XCTAssertEqual(row.last!.maxX, size.width - 3, accuracy: 0.01)
                }
                for (a, b) in zip(row, row.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(b.minX, a.maxX - 0.01, "keys overlap")
                }
            }
        }
    }

    func testRowsStayBelowTheBubbleStrip() {
        let frames = KeyGeometry.frames(rows: KeyLayout.rows(for: .letters),
                                        in: size, topInset: 46)
        XCTAssertGreaterThanOrEqual(frames[0][0].minY, 46)
        XCTAssertLessThanOrEqual(frames.last!.last!.maxY, size.height + 0.01)
    }

    func testDegenerateSizesProduceNothingRatherThanNaNs() {
        XCTAssertTrue(KeyGeometry.frames(rows: KeyLayout.rows(for: .letters),
                                         in: .zero, topInset: 46).isEmpty)
        XCTAssertTrue(KeyGeometry.frames(rows: [], in: size, topInset: 46).isEmpty)
    }
}
