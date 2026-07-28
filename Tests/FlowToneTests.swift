import XCTest
@testable import FlowBoard

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
