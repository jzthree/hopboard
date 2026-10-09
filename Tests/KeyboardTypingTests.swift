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
    private let phone = KeyboardMetrics.forWidth(393, idiom: .phone)

    func testKeysFillTheWidthWithoutOverlapping() {
        for layer in [KeyLayer.letters, .numbers, .symbols] {
            let rows = KeyLayout.rows(for: layer)
            let frames = KeyGeometry.frames(rows: rows, in: size, metrics: phone)
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
                                        in: size, metrics: phone)
        XCTAssertGreaterThanOrEqual(frames[0][0].minY, phone.topInset)
        // Clear of the bottom edge, not flush with it.
        XCTAssertLessThan(frames.last!.last!.maxY, size.height)
    }

    func testDegenerateSizesProduceNothingRatherThanNaNs() {
        XCTAssertTrue(KeyGeometry.frames(rows: KeyLayout.rows(for: .letters),
                                         in: .zero, metrics: phone).isEmpty)
        XCTAssertTrue(KeyGeometry.frames(rows: [], in: size, metrics: phone).isEmpty)
    }
}

final class WordBoundaryTests: XCTestCase {
    func testCurrentWordIsTheTrailingRun() {
        XCTAssertEqual(TypingEngine.currentWord(in: "the quick brow"), "brow")
        XCTAssertEqual(TypingEngine.currentWord(in: "don't"), "don't")
        XCTAssertEqual(TypingEngine.currentWord(in: "done. "), "")
        XCTAssertEqual(TypingEngine.currentWord(in: ""), "")
    }

    func testReplacingTouchesOnlyTheLastWord() {
        XCTAssertEqual(TypingEngine.replacingCurrentWord(in: "the teh", with: "the"),
                       "the the")
        XCTAssertEqual(TypingEngine.replacingCurrentWord(in: "hi ", with: "x"), "hi x")
    }

    func testWhatEndsAWord() {
        XCTAssertTrue(TypingEngine.endsWord(" "))
        XCTAssertTrue(TypingEngine.endsWord("."))
        XCTAssertTrue(TypingEngine.endsWord("1"))
        XCTAssertFalse(TypingEngine.endsWord("a"))
        XCTAssertFalse(TypingEngine.endsWord("'"))
        XCTAssertFalse(TypingEngine.endsWord(""))
    }
}

final class AutocorrectTests: XCTestCase {
    private var subject: Autocorrect!
    private let key = "kb.tests.keptWords"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
        subject = Autocorrect(language: "en_US", keptKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testFixesAnOrdinaryTypo() {
        XCTAssertEqual(subject.correction(for: "teh"), "the")
    }

    func testLeavesCorrectWordsAlone() {
        XCTAssertNil(subject.correction(for: "the"))
        XCTAssertNil(subject.correction(for: "keyboard"))
    }

    /// The expensive mistakes are not typos. A keyboard that "fixes" a
    /// password, a path or an identifier has destroyed something the user
    /// cannot retype from memory.
    func testRefusesAnythingThatIsNotAnOrdinaryWord() {
        XCTAssertFalse(subject.isCorrectable("hunter2"))
        XCTAssertFalse(subject.isCorrectable("usr/lib"))
        XCTAssertFalse(subject.isCorrectable("HopBoard"))
        XCTAssertFalse(subject.isCorrectable("xQ"))      // too short to judge
        XCTAssertTrue(subject.isCorrectable("teh"))
    }

    func testRefusingACorrectionTeachesIt() {
        XCTAssertNotNil(subject.correction(for: "teh"))
        subject.keep("teh")
        XCTAssertNil(subject.correction(for: "teh"), "a kept word is never corrected again")
        XCTAssertTrue(subject.suggestions(for: "teh").isEmpty)
        // And it survives the keyboard being torn down and rebuilt.
        XCTAssertTrue(Autocorrect(language: "en_US", keptKey: key).isKept("TEH"))
    }

    func testSuggestionsLeadWithTheLiteralAndMarkOneDefault() {
        let suggestions = subject.suggestions(for: "teh")
        XCTAssertEqual(suggestions.first?.text, "teh")
        XCTAssertEqual(suggestions.first?.isLiteral, true)
        XCTAssertEqual(suggestions.filter(\.isDefault).count, 1)
        XCTAssertEqual(suggestions.first(where: \.isDefault)?.text, "the")
    }
}

/// "I should never be able to tap and nothing lands." (Jian, 2026-10-04)
/// A dead tap is the worst outcome a keyboard has: it teaches you nothing
/// about where you missed, so you cannot aim better, and it leaves you
/// unsure the keyboard is even alive. A wrong character is visible, says
/// the tap registered, and backspace is one key away.
final class DeadTapTests: XCTestCase {
    private let size = CGSize(width: 393, height: 258)
    private let phone = KeyboardMetrics.forWidth(393, idiom: .phone)

    private func frames(_ layer: KeyLayer) -> [[CGRect]] {
        KeyGeometry.frames(rows: KeyLayout.rows(for: layer), in: size, metrics: phone)
    }

    func testEveryPointOnThePlaneBelongsToAKey() {
        for layer in [KeyLayer.letters, .numbers, .symbols] {
            let grid = frames(layer)
            var dead: [CGPoint] = []
            for x in stride(from: CGFloat(0), through: size.width, by: 3) {
                for y in stride(from: CGFloat(0), through: size.height, by: 3) {
                    let point = CGPoint(x: x, y: y)
                    if KeyGeometry.index(at: point, in: grid) == nil { dead.append(point) }
                }
            }
            XCTAssertTrue(dead.isEmpty,
                          "\(layer) has \(dead.count) dead points, first \(dead.first!)")
        }
    }

    /// The places that WERE dead: the gap between two keys, both side
    /// insets, and the bottom margin.
    func testThePreviouslyDeadPlacesResolve() {
        let grid = frames(.letters)
        let first = grid[0][0]
        let second = grid[0][1]
        let gap = CGPoint(x: (first.maxX + second.minX) / 2, y: first.midY)
        XCTAssertNotNil(KeyGeometry.index(at: gap, in: grid))
        XCTAssertNotNil(KeyGeometry.index(at: CGPoint(x: 0, y: first.midY), in: grid))
        XCTAssertNotNil(KeyGeometry.index(at: CGPoint(x: size.width, y: first.midY), in: grid))
        XCTAssertNotNil(KeyGeometry.index(at: CGPoint(x: size.width / 2,
                                                      y: size.height), in: grid))
        // Including the strip above the keys, when no candidates occupy it.
        XCTAssertNotNil(KeyGeometry.index(at: CGPoint(x: 20, y: 2), in: grid))
    }

    /// Generosity must not cost accuracy: a point inside a key is still
    /// that key, never a nearer-centre neighbour.
    func testAPointInsideAKeyIsThatKey() {
        let grid = frames(.letters)
        for (rowIndex, row) in grid.enumerated() {
            for (colIndex, frame) in row.enumerated() {
                let found = KeyGeometry.index(at: CGPoint(x: frame.midX, y: frame.midY),
                                              in: grid)
                XCTAssertEqual(found?.row, rowIndex)
                XCTAssertEqual(found?.col, colIndex)
            }
        }
    }
}

extension AutocorrectTests {
    /// Dashes out of nowhere: UITextChecker offers hyphenated and split
    /// forms for compounds it does not know, and applying one breaks a
    /// word that was typed deliberately. A correction is a WORD.
    func testCorrectionsAreAlwaysOneOrdinaryWord() {
        let checker = Autocorrect(language: "en_US", keptKey: "kb.tests.plainWords")
        defer { UserDefaults.standard.removeObject(forKey: "kb.tests.plainWords") }
        for word in ["hopboard", "teh", "recieve", "definately", "wierd",
                     "seperate", "keyboardd", "thats", "alot", "everytime"] {
            if let fix = checker.correction(for: word) {
                XCTAssertFalse(fix.contains("-"), "\(word) -> \(fix) inserted a dash")
                XCTAssertFalse(fix.contains(" "), "\(word) -> \(fix) split the word")
            }
            for suggestion in checker.suggestions(for: word) {
                XCTAssertFalse(suggestion.text.contains("-"),
                               "\(word) offered \(suggestion.text)")
                XCTAssertFalse(suggestion.text.contains(" "),
                               "\(word) offered \(suggestion.text)")
            }
        }
    }
}

final class KeyboardMetricsTests: XCTestCase {
    private let phone = KeyboardMetrics.forWidth(393, idiom: .phone)
    private let phoneWide = KeyboardMetrics.forWidth(852, idiom: .phone)
    private let pad = KeyboardMetrics.forWidth(820, idiom: .pad)
    private let padWide = KeyboardMetrics.forWidth(1180, idiom: .pad)

    /// A phone on its side is ~390pt tall. A portrait-sized keyboard there
    /// leaves nothing of the screen for the thing being typed into.
    func testLandscapePhoneIsMuchShorter() {
        XCTAssertLessThan(phoneWide.typingHeight, phone.typingHeight * 0.75)
        XCTAssertLessThan(phoneWide.topInset, phone.topInset)
    }

    /// And a tablet is not a stretched phone: resting hands want real keys.
    func testPadIsBiggerThanAnyPhone() {
        XCTAssertGreaterThan(pad.typingHeight, phone.typingHeight)
        XCTAssertGreaterThan(padWide.typingHeight, pad.typingHeight)
        XCTAssertGreaterThan(pad.keySpacing, phone.keySpacing)
    }

    /// Shape, not device. Width alone stopped being enough the moment a
    /// folding phone existed: a phone on its side and a foldable opened up
    /// are both wide, and only one of them wants a squashed keyboard.
    func testShapeDecidesNotWidthOrDeviceName() {
        XCTAssertTrue(KeyboardMetrics.isShortScreen(393))
        XCTAssertFalse(KeyboardMetrics.isShortScreen(852))
        // Phone on its side: wide, short.
        XCTAssertFalse(KeyboardMetrics.isTabletShaped(width: 852, height: 393,
                                                      idiom: .phone))
        // A foldable opened up: wide AND tall. Tablet-shaped, whatever the
        // idiom says, and whatever the device turns out to be called.
        XCTAssertTrue(KeyboardMetrics.isTabletShaped(width: 744, height: 1080,
                                                     idiom: .phone))
        // Folded again: an ordinary upright phone.
        XCTAssertFalse(KeyboardMetrics.isTabletShaped(width: 390, height: 1080,
                                                      idiom: .phone))
    }

    /// The backstop for a form factor nobody here has held: get the class
    /// wrong and the keys are the wrong size, but what you are typing into
    /// is still on screen.
    func testTheKeyboardNeverEatsHalfTheScreen() {
        for (width, height) in [(393.0, 852.0), (852.0, 393.0), (744.0, 1080.0),
                                (820.0, 1180.0), (375.0, 667.0), (320.0, 480.0)] {
            let metrics = KeyboardMetrics.forScreen(width: width, height: height,
                                                    idiom: .phone)
            XCTAssertLessThanOrEqual(metrics.typingHeight, height * 0.48 + 0.01,
                                     "\(width)x\(height) keyboard too tall")
            XCTAssertGreaterThan(metrics.topInset, 20)
            XCTAssertGreaterThan(metrics.typingHeight, metrics.topInset * 2)
        }
    }

    /// An unfolded foldable must not be mistaken for a sideways phone and
    /// handed the squashed landscape strip.
    func testAnUnfoldedFoldableGetsRealKeys() {
        let unfolded = KeyboardMetrics.forScreen(width: 744, height: 1080, idiom: .phone)
        let sideways = KeyboardMetrics.forScreen(width: 852, height: 393, idiom: .phone)
        XCTAssertGreaterThan(unfolded.typingHeight, sideways.typingHeight * 1.5)
        XCTAssertGreaterThan(unfolded.keySpacing, sideways.keySpacing)
    }

    /// The invariants have to hold on every device, not just the one the
    /// numbers were tuned on.
    func testNoDeadTapsAndNoOverlapOnAnyDevice() {
        let cases: [(String, CGSize, KeyboardMetrics)] = [
            ("phone portrait", CGSize(width: 393, height: phone.typingHeight), phone),
            ("phone landscape", CGSize(width: 852, height: phoneWide.typingHeight), phoneWide),
            ("pad portrait", CGSize(width: 820, height: pad.typingHeight), pad),
            ("pad landscape", CGSize(width: 1180, height: padWide.typingHeight), padWide),
        ]
        for (name, size, metrics) in cases {
            for layer in [KeyLayer.letters, .numbers, .symbols] {
                let grid = KeyGeometry.frames(rows: KeyLayout.rows(for: layer),
                                              in: size, metrics: metrics)
                XCTAssertEqual(grid.count, 4, "\(name)/\(layer)")
                for row in grid {
                    for (a, b) in zip(row, row.dropFirst()) {
                        XCTAssertGreaterThanOrEqual(b.minX, a.maxX - 0.01,
                                                    "\(name)/\(layer) keys overlap")
                    }
                    XCTAssertGreaterThan(row[0].height, 20, "\(name) keys too short")
                }
                for x in stride(from: CGFloat(0), through: size.width, by: 7) {
                    for y in stride(from: CGFloat(0), through: size.height, by: 7) {
                        XCTAssertNotNil(
                            KeyGeometry.index(at: CGPoint(x: x, y: y), in: grid),
                            "\(name)/\(layer) dead at \(x),\(y)")
                    }
                }
            }
        }
    }
}

final class CorrectionConfidenceTests: XCTestCase {
    private let key = "kb.tests.confidence"
    private var subject: Autocorrect!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
        subject = Autocorrect(language: "en_US", keptKey: key)
    }
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    /// Fingers transpose. Charging two edits for a swap would refuse the
    /// commonest typo there is.
    func testTranspositionCostsOneEdit() {
        XCTAssertEqual(TypingEngine.editDistance("teh", "the"), 1)
        XCTAssertEqual(TypingEngine.editDistance("recieve", "receive"), 1)
        XCTAssertEqual(TypingEngine.editDistance("cat", "cat"), 0)
        XCTAssertEqual(TypingEngine.editDistance("mybot", "robot"), 2)
        XCTAssertEqual(TypingEngine.editDistance("", "abc"), 3)
    }

    /// The general rule behind "even mybot gets corrected": UITextChecker
    /// answers every question as though it knew, and for a name or a piece
    /// of jargon its nearest word can be several edits away. Distance IS
    /// the confidence it does not report.
    func testOnlyNearMissesAreAppliedAutomatically() {
        for word in ["mybot", "hopboard", "zsh", "kubectl", "claude", "testflight",
                     "whisperkit", "xcodegen"] {
            if let fix = subject.correction(for: word) {
                XCTAssertLessThanOrEqual(
                    TypingEngine.editDistance(word, fix),
                    Autocorrect.editBudget(for: word),
                    "\(word) -> \(fix) is too far to be a correction")
            }
        }
        // A real slip still gets fixed; timid is not the same as useless.
        XCTAssertEqual(subject.correction(for: "teh"), "the")
    }

    func testLongerWordsEarnSlightlyMoreRoom() {
        XCTAssertEqual(Autocorrect.editBudget(for: "teh"), 1)
        XCTAssertEqual(Autocorrect.editBudget(for: "definately"), 2)
    }

    /// Only the replacement a word break will actually apply may be marked
    /// default — otherwise the bar promises something that never happens.
    func testDefaultSlotMatchesWhatWillBeApplied() {
        for word in ["mybot", "teh", "hopboard", "wierd"] {
            let suggestions = subject.suggestions(for: word)
            let marked = suggestions.first(where: \.isDefault)?.text
            XCTAssertEqual(marked, subject.correction(for: word),
                           "the bar's default disagrees with auto-apply for \(word)")
        }
    }
}

/// The keys were eleven points tall on build 85, because the height
/// constraint kept the value it was born with after the call that
/// overrode it was deleted. Geometry alone could not catch that — the
/// layout was correct, it was just being handed the wrong box. So the
/// test is on the box: whatever height the metrics hand out, keys that
/// come out of it have to be reachable by a finger.
final class KeyHeightTests: XCTestCase {
    func testEveryDeviceGetsKeysAFingerCanHit() {
        let screens: [(String, CGFloat, CGFloat, UIUserInterfaceIdiom)] = [
            ("phone portrait", 393, 852, .phone),
            ("phone landscape", 852, 393, .phone),
            ("small phone", 375, 667, .phone),
            ("pad portrait", 820, 1180, .pad),
            ("pad landscape", 1180, 820, .pad),
            ("foldable open", 744, 1080, .phone),
        ]
        for (name, width, height, idiom) in screens {
            let metrics = KeyboardMetrics.forScreen(width: width, height: height,
                                                    idiom: idiom)
            let size = CGSize(width: width, height: metrics.typingHeight)
            let grid = KeyGeometry.frames(rows: KeyLayout.rows(for: .letters),
                                          in: size, metrics: metrics)
            let keyHeight = grid[0][0].height
            // Apple's own guidance is 44pt; a keyboard packs tighter than
            // that, but 28 is the floor where aiming stops working.
            XCTAssertGreaterThanOrEqual(keyHeight, 28,
                                        "\(name): keys are \(keyHeight)pt tall")
            XCTAssertGreaterThan(metrics.typingHeight, metrics.topInset * 2,
                                 "\(name): the strip is eating the keyboard")
        }
    }
}

final class SpaceBarTests: XCTestCase {
    /// Space is hit most and aimed at least, so it takes about half the
    /// bottom row — the share the system keyboard gives it, and the share
    /// it got back when the globe was removed.
    func testSpaceOwnsAboutHalfTheBottomRow() {
        let metrics = KeyboardMetrics.forWidth(393, idiom: .phone)
        let row = KeyGeometry.frames(rows: KeyLayout.rows(for: .letters),
                                     in: CGSize(width: 393, height: 258),
                                     metrics: metrics)[3]
        XCTAssertEqual(row.count, 4)
        let share = row[2].width / (row.last!.maxX - row.first!.minX)
        XCTAssertGreaterThan(share, 0.45, "space is only \(Int(share * 100))%")
        XCTAssertLessThan(share, 0.62)
        for key in row {
            XCTAssertGreaterThanOrEqual(key.width, 34,
                                        "a bottom-row key is only \(key.width)pt")
        }
    }

    /// No input-mode switch key, by decision. If one ever comes back it
    /// must not come back out of the space bar.
    func testNoGlobeInTheLayout() {
        for layer in [KeyLayer.letters, .numbers, .symbols] {
            let labels = KeyLayout.rows(for: layer).flatMap { $0.keys.compactMap(\.symbolName) }
            XCTAssertFalse(labels.contains("globe"))
        }
    }
}
