import XCTest
@testable import FlowBoard

final class InMemoryBackend: FlowBackend {
    private var storage: [String: Data] = [:]
    func data(forKey key: String) -> Data? { storage[key] }
    func set(_ data: Data, forKey key: String) { storage[key] = data }
    func removeValue(forKey key: String) { storage[key] = nil }
    func keys(withPrefix prefix: String) -> [String] {
        storage.keys.filter { $0.hasPrefix(prefix) }
    }
}

final class FlowIPCTests: XCTestCase {
    // In-memory backend so tests never touch the real keychain group.
    private var store: FlowStore!

    override func setUp() {
        store = FlowStore(backend: InMemoryBackend())
    }

    func testCommandQueuePreservesOrderAndDrainsOnce() {
        store.send(.startSegment)
        store.send(.stopSegment)
        let taken = store.takeCommands()
        XCTAssertEqual(taken.map(\.action), [.startSegment, .stopSegment],
                       "a fast start+stop pair must survive as a pair, in order")
        XCTAssertTrue(store.takeCommands().isEmpty, "commands drain exactly once")
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

    func testQuietCutIndexFindsSilence() {
        // 30 s of loud signal with a quiet patch at 27 s: the cut should
        // land inside the patch, not at the hard 30 s boundary.
        let rate = Int(AudioRecorder.targetSampleRate)
        var samples = [Float](repeating: 0.5, count: rate * 31)
        for i in (rate * 27)..<(rate * 27 + rate / 2) { samples[i] = 0.0001 }
        let cut = AudioRecorder.quietCutIndex(in: samples)
        XCTAssertGreaterThan(cut, rate * 26)
        XCTAssertLessThan(cut, rate * 28)
    }

    func testQuietCutIndexUniformFallsBackToWindowEnd() {
        let rate = Int(AudioRecorder.targetSampleRate)
        let samples = [Float](repeating: 0.5, count: rate * 30)
        let cut = AudioRecorder.quietCutIndex(in: samples)
        // Uniform energy: any cut in the search region is fine, but it must
        // stay inside the completed window.
        XCTAssertLessThanOrEqual(cut, rate * 30)
        XCTAssertGreaterThan(cut, rate * 24)
    }

    func testNormalizeCJKPunctuation() {
        XCTAssertEqual(FlowText.normalizeCJKPunctuation("对我做了介绍.我想说,大家好!"),
                       "对我做了介绍。我想说，大家好！")
        // Latin context untouched, decimals untouched.
        XCTAssertEqual(FlowText.normalizeCJKPunctuation("Hello, world. 3.5 percent"),
                       "Hello, world. 3.5 percent")
        // Mixed: convert only after CJK characters.
        XCTAssertEqual(FlowText.normalizeCJKPunctuation("他说,see you. 好的!"),
                       "他说，see you. 好的！")
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
