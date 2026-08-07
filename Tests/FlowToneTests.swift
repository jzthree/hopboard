import XCTest
@testable import HopBoard

final class FlowToneTests: XCTestCase {
    func testFormal() {
        XCTAssertEqual(FlowTone.formal.apply(to: "hello there"), "Hello there.")
        XCTAssertEqual(FlowTone.formal.apply(to: "Hello there."), "Hello there.")
        XCTAssertEqual(FlowTone.formal.apply(to: "really?"), "Really?")
        XCTAssertEqual(FlowTone.formal.apply(to: "你好"), "你好。")
        XCTAssertEqual(FlowTone.formal.apply(to: ""), "")
    }

    func testCasualDropsOnlyTrailingPeriod() {
        XCTAssertEqual(FlowTone.casual.apply(to: "Hello there."), "Hello there")
        XCTAssertEqual(FlowTone.casual.apply(to: "Hello there!"), "Hello there!")
        XCTAssertEqual(FlowTone.casual.apply(to: "Wait..."), "Wait...")
        XCTAssertEqual(FlowTone.casual.apply(to: "你好。"), "你好")
    }

    func testVeryCasualLowercases() {
        XCTAssertEqual(FlowTone.veryCasual.apply(to: "Hello There."), "hello there")
        XCTAssertEqual(FlowTone.veryCasual.apply(to: "OK, sounds Good!"), "ok, sounds good!")
    }

    func testExcited() {
        XCTAssertEqual(FlowTone.excited.apply(to: "this is great."), "This is great!")
        XCTAssertEqual(FlowTone.excited.apply(to: "this is great"), "This is great!")
        XCTAssertEqual(FlowTone.excited.apply(to: "Already excited!"), "Already excited!")
        XCTAssertEqual(FlowTone.excited.apply(to: "is it real?"), "Is it real?")
        XCTAssertEqual(FlowTone.excited.apply(to: "太好了。"), "太好了！")
    }
}

final class AppleSpeechEngineTests: XCTestCase {
    @available(iOS 26.0, *)
    func testLocaleMapping() {
        XCTAssertEqual(AppleSpeechEngine.locale(for: "zh").identifier, "zh_CN")
        XCTAssertEqual(AppleSpeechEngine.locale(for: "en").identifier, "en_US")
        XCTAssertEqual(AppleSpeechEngine.locale(for: "ja").identifier, "ja")
        XCTAssertEqual(AppleSpeechEngine.locale(for: "auto"), Locale.current)
        XCTAssertEqual(AppleSpeechEngine.locale(for: nil), Locale.current)
    }
}

@MainActor
final class ModelChoiceMigrationTests: XCTestCase {
    /// Anyone still pinned to a removed engine must land on a real one:
    /// a Picker whose selection matches no tag renders a blank row.
    func testRemovedEnginesFallBack() {
        XCTAssertEqual(SessionManager.migratedModelChoice("gemma"), "turbo")
        XCTAssertEqual(SessionManager.migratedModelChoice("litert"), "turbo")
        XCTAssertEqual(SessionManager.migratedModelChoice(nil), "turbo")
        XCTAssertEqual(SessionManager.migratedModelChoice(""), "turbo")
    }

    func testShippingEnginesSurvive() {
        for choice in SessionManager.modelChoices {
            XCTAssertEqual(SessionManager.migratedModelChoice(choice), choice)
        }
        // Guard the list itself: every tag the picker offers must be here.
        XCTAssertEqual(SessionManager.modelChoices, ["turbo", "accurate", "apple"])
    }
}
