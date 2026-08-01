import XCTest
@testable import HopBoard

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
        let result = FlowResult(id: UUID(), text: "hello world",
                                finishedAt: Date().timeIntervalSince1970)
        store.append(result)
        XCTAssertEqual(store.nextUnconsumedResult(), result)
        store.lastConsumedResultID = result.id
        XCTAssertNil(store.nextUnconsumedResult())
    }

    func testResultsExpireAfterADay() {
        let old = FlowResult(id: UUID(), text: "yesterday",
                             finishedAt: Date().timeIntervalSince1970 - 25 * 3600)
        let fresh = FlowResult(id: UUID(), text: "now",
                               finishedAt: Date().timeIntervalSince1970)
        store.append(old)
        store.append(fresh)
        XCTAssertEqual(store.results.map(\.text), ["now"])
    }

    func testResultsAreCapped() {
        let now = Date().timeIntervalSince1970
        for i in 0..<30 {
            store.append(FlowResult(id: UUID(), text: "\(i)", finishedAt: now + Double(i)))
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
        let cut = AudioRecorder.quietCutIndex(in: samples, windowFrames: rate * 30)
        XCTAssertGreaterThan(cut, rate * 26)
        XCTAssertLessThan(cut, rate * 28)
    }

    func testQuietCutIndexUniformFallsBackToWindowEnd() {
        let rate = Int(AudioRecorder.targetSampleRate)
        let samples = [Float](repeating: 0.5, count: rate * 30)
        let cut = AudioRecorder.quietCutIndex(in: samples, windowFrames: rate * 30)
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
        // Apple's transcriber pads full-width marks with a stray space.
        XCTAssertEqual(FlowText.normalizeCJKPunctuation("那么我想说的是呢 ，大家好 ？"),
                       "那么我想说的是呢，大家好？")
        // Latin sentence spacing is untouched by the space cleanup.
        XCTAssertEqual(FlowText.normalizeCJKPunctuation("Yes , I mean it"),
                       "Yes , I mean it")
    }

    func testWhisperCodeFromLanguageTag() {
        // iOS preferred-language tags and AppleKeyboards entries.
        XCTAssertEqual(FlowText.whisperCode(fromLanguageTag: "en-US"), "en")
        XCTAssertEqual(FlowText.whisperCode(fromLanguageTag: "zh-Hans-CN"), "zh")
        XCTAssertEqual(FlowText.whisperCode(fromLanguageTag: "zh_Hans-Pinyin@sw=Pinyin10"), "zh")
        XCTAssertEqual(FlowText.whisperCode(fromLanguageTag: "yue-CN"), "yue")
        // Non-language entries are rejected, including our own keyboard id.
        XCTAssertNil(FlowText.whisperCode(fromLanguageTag: "emoji"))
        XCTAssertNil(FlowText.whisperCode(fromLanguageTag: "Emoji@sw=Emoji"))
        XCTAssertNil(FlowText.whisperCode(fromLanguageTag: ""))
    }

    func testFavoriteLanguages() {
        XCTAssertEqual(store.favoriteLanguages, ["auto", "en", "zh"])
        store.favoriteLanguages = ["en", "zh", "ja"]
        XCTAssertEqual(store.favoriteLanguages, ["en", "zh", "ja"])
        XCTAssertTrue(store.autoLanguageAllowed)
        store.autoLanguageAllowed = false
        XCTAssertFalse(store.autoLanguageAllowed)
        store.autoLanguageAllowed = true
        XCTAssertTrue(store.autoLanguageAllowed)
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

final class FlowVocabularyTests: XCTestCase {
    private let terms = ["HopBoard", "Anthropic", "张伟", "Kubernetes"]

    func testCasingAndSplitting() {
        // The three ways a model renders one written name.
        XCTAssertEqual(FlowVocabulary.apply("I opened hop board today.", terms: terms),
                       "I opened HopBoard today.")
        XCTAssertEqual(FlowVocabulary.apply("hopboard is running.", terms: terms),
                       "HopBoard is running.")
        XCTAssertEqual(FlowVocabulary.apply("Ship HOPBOARD now", terms: terms),
                       "Ship HopBoard now")
    }

    func testMishearing() {
        XCTAssertEqual(FlowVocabulary.apply("the hop bored build", terms: terms),
                       "the HopBoard build")
        XCTAssertEqual(FlowVocabulary.apply("works at anthropik", terms: terms),
                       "works at Anthropic")
        XCTAssertEqual(FlowVocabulary.apply("deploy to kubernetties", terms: terms),
                       "deploy to Kubernetes")
    }

    func testChineseHomophones() {
        // Same pinyin, wrong glyph — how Chinese recognition actually fails.
        XCTAssertEqual(FlowVocabulary.apply("这是章伟的项目", terms: terms),
                       "这是张伟的项目")
        XCTAssertEqual(FlowVocabulary.apply("张伟已经完成", terms: terms),
                       "张伟已经完成")
    }

    func testLeavesOrdinaryTextAlone() {
        let text = "The board meeting is on Monday and the hope is high."
        XCTAssertEqual(FlowVocabulary.apply(text, terms: terms), text)
        XCTAssertEqual(FlowVocabulary.apply("我们在开会", terms: terms), "我们在开会")
        // No terms configured: never touch the transcript.
        XCTAssertEqual(FlowVocabulary.apply("hop board", terms: []), "hop board")
    }

    func testTermParsing() {
        XCTAssertEqual(FlowVocabulary.terms(from: "HopBoard\n 张伟 \n\nAnthropic, Claude\nx"),
                       ["HopBoard", "张伟", "Anthropic", "Claude"])
    }

    func testPinyin() {
        XCTAssertEqual(FlowVocabulary.pinyin("张伟"), FlowVocabulary.pinyin("章伟"))
        XCTAssertNotEqual(FlowVocabulary.pinyin("张伟"), FlowVocabulary.pinyin("李明"))
    }
}
