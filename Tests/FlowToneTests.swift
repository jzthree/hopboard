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

final class GemmaOutputTests: XCTestCase {
    func testStripThinking() {
        XCTAssertEqual(GemmaEngine.stripThinking(
            "<|channel>thought\nReasoning here.<channel|>hello world\n"),
            "hello world")
        XCTAssertEqual(GemmaEngine.stripThinking("plain answer<end_of_turn>"),
                       "plain answer")
        XCTAssertEqual(GemmaEngine.stripThinking(
            "<|channel>thought a <channel|> mid <|channel>thought b <channel|>final"),
            "final")
    }

    /// The config screen previews assemblePrompt as "the exact prompt" —
    /// pin the template so a drive-by edit can't silently change what both
    /// the preview and transcribe() produce.
    func testAssemblePrompt() {
        let plain = GemmaEngine.assemblePrompt(instruction: "Transcribe.", thinking: false)
        XCTAssertTrue(plain.hasPrefix("<|turn>user\nTranscribe. "))
        XCTAssertTrue(plain.hasSuffix("<turn|>\n<|turn>model\n"))
        // The audio marker sits between instruction and end-of-turn.
        XCTAssertFalse(plain.contains("<|channel>thought"))
        let thinking = GemmaEngine.assemblePrompt(instruction: "Transcribe.", thinking: true)
        XCTAssertEqual(thinking, plain + "<|channel>thought\n")
    }
}
