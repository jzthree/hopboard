import XCTest
@testable import FlowBoard

final class InMemoryBackend: FlowBackend {
    private var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func set(_ data: Data, forKey key: String) { storage[key] = data }
    func removeValue(forKey key: String) { storage[key] = nil }
}

final class FlowIPCTests: XCTestCase {
    // In-memory backend so tests never touch the real keychain group.
    private var store: FlowStore!

    override func setUp() {
        store = FlowStore(backend: InMemoryBackend())
    }

    func testCommandRoundTripIsConsumedOnce() {
        store.send(.startSegment)
        let taken = store.takeCommand()
        XCTAssertEqual(taken?.action, .startSegment)
        XCTAssertNil(store.takeCommand(), "a command must be consumed exactly once")
    }

    func testResultConsumption() {
        XCTAssertNil(store.nextUnconsumedResult())
        let result = FlowResult(id: UUID(), text: "hello world", finishedAt: 123)
        store.append(result)
        XCTAssertEqual(store.nextUnconsumedResult(), result)
        store.lastConsumedResultID = result.id
        XCTAssertNil(store.nextUnconsumedResult())
    }

    func testResultsAreCapped() {
        for i in 0..<30 {
            store.append(FlowResult(id: UUID(), text: "\(i)", finishedAt: Double(i)))
        }
        XCTAssertEqual(store.results.count, 20)
        XCTAssertEqual(store.results.last?.text, "29")
    }

    func testSessionAliveRequiresFreshHeartbeat() {
        store.state = .ready
        store.heartbeat = Date(timeIntervalSinceNow: -60)
        XCTAssertFalse(store.sessionAlive)
        store.heartbeat = Date()
        XCTAssertTrue(store.sessionAlive)
        store.state = .idle
        XCTAssertFalse(store.sessionAlive)
    }

    func testSmartJoin() {
        XCTAssertEqual(FlowText.smartJoin(before: nil, insertion: "Hello"), "Hello")
        XCTAssertEqual(FlowText.smartJoin(before: "", insertion: "Hello"), "Hello")
        XCTAssertEqual(FlowText.smartJoin(before: "Hi.", insertion: "Hello"), " Hello")
        XCTAssertEqual(FlowText.smartJoin(before: "Hi. ", insertion: "Hello"), "Hello")
        XCTAssertEqual(FlowText.smartJoin(before: "line\n", insertion: "Hello"), "Hello")
        XCTAssertEqual(FlowText.smartJoin(before: "(", insertion: "Hello"), "Hello")
        XCTAssertEqual(FlowText.smartJoin(before: "word", insertion: "  spaced  "), " spaced")
        XCTAssertEqual(FlowText.smartJoin(before: "word", insertion: "   "), "")
    }
}
