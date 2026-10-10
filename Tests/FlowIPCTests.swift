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

    private func verdict(before: String? = nil, after: String?, tail: String,
                         isSecure: Bool = false, hasText: Bool) -> InsertVerdict {
        FlowText.insertVerdict(contextBefore: before, contextAfter: after,
                               insertedTail: tail, isSecure: isSecure, hasText: hasText)
    }

    func testInsertLandedRequiresOurTextAtTheCursor() {
        let inserted = FlowText.foldTail(" Hello there, this is a test.")

        // THE FIRST REGRESSION: the host had not yet delivered the document
        // context when we inserted (it is asynchronous and routinely nil
        // just after the keyboard appears), then filled it in on its own.
        // The old before/after comparison saw "it changed" and reported a
        // successful insert, so the dictation was marked delivered while
        // nothing had been typed. Existing text that is not ours must read
        // as a failure.
        XCTAssertEqual(verdict(after: "text that was already there",
                               tail: inserted, hasText: true), .notAtCursor)
        // Nothing focused: no context at all.
        XCTAssertEqual(verdict(after: nil, tail: inserted, hasText: false), .noField)
        // Claims text but reports no context: unknowable, not a failure.
        XCTAssertEqual(verdict(after: nil, tail: inserted, hasText: true), .unreadable)
        XCTAssertEqual(verdict(after: "", tail: inserted, hasText: true), .unreadable)
        // It landed: the context now ends with what we sent.
        XCTAssertEqual(verdict(after: "Before. Hello there, this is a test.",
                               tail: inserted, hasText: true), .landed)
        // Landed into an empty field.
        XCTAssertEqual(verdict(after: "Hello there, this is a test.",
                               tail: inserted, hasText: true), .landed)
        // The host's own capitalization/spacing tweak still counts.
        XCTAssertEqual(verdict(after: "hello there this is a Test",
                               tail: inserted, hasText: true), .landed)
        // Chinese, where folding must keep the characters themselves.
        let cjk = FlowText.foldTail("你好，世界。")
        XCTAssertFalse(cjk.isEmpty)
        XCTAssertEqual(verdict(after: "开始 你好，世界。", tail: cjk, hasText: true), .landed)
        XCTAssertEqual(verdict(after: "开始", tail: cjk, hasText: true), .notAtCursor)
    }

    func testFieldThatAlreadyEndedWithOurTextCannotConfirmItself() {
        // THE SECOND REGRESSION, and the reason this looked intermittent:
        // the tail is only 12 folded characters, so a short dictation into a
        // field that ALREADY ends that way passes the suffix test without
        // anything being typed. Say "yes" twice, lose the second one, and
        // both read as delivered. Only growth is evidence there.
        let tail = FlowText.foldTail("Yes")
        XCTAssertEqual(verdict(before: "Ready? yes", after: "Ready? yes",
                               tail: tail, hasText: true), .notAtCursor)
        XCTAssertEqual(verdict(before: "Ready? yes", after: "Ready? yes yes",
                               tail: tail, hasText: true), .landed)
        // Unknown before-context stays trusting: refusing every insert we
        // cannot double-check would strand text in history, which is the
        // failure this whole path exists to prevent.
        XCTAssertEqual(verdict(before: nil, after: "Ready? yes",
                               tail: tail, hasText: true), .landed)
    }

    func testSecureFieldsAreTrustedOnlyWhenTheyHoldText() {
        let inserted = FlowText.foldTail("hunter2")
        // Password fields withhold the context, so an insert there can never
        // be read back — but an EMPTY one still proves nothing landed.
        // Trusting them unconditionally turned every swallowed insert into a
        // password field into a silent success.
        XCTAssertEqual(verdict(after: nil, tail: inserted,
                               isSecure: true, hasText: true), .landedUnverifiable)
        XCTAssertEqual(verdict(after: nil, tail: inserted,
                               isSecure: true, hasText: false), .noField)
    }

    func testPunctuationOnlyInsertFallsBackToHasText() {
        // A lone "。" folds to nothing — there is no tail to look for.
        let empty = FlowText.foldTail("。")
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(verdict(after: "开始。", tail: empty, hasText: true),
                       .landedUnverifiable)
        XCTAssertEqual(verdict(after: "", tail: empty, hasText: false), .noField)
    }

    /// A terminal reports its document from an IME composition buffer that
    /// it clears, so the context goes from "ends with our text" to empty
    /// while the text sits on screen. That must not read as the host
    /// undoing the edit — it is why auto-insert into hop-ios stopped.
    func testTerminalStyleContextLossIsNotARevert() {
        let inserted = FlowText.foldTail("deploy the thing")
        // Right after the insert the buffer still holds it.
        XCTAssertEqual(verdict(after: "deploy the thing", tail: inserted,
                               hasText: true), .landed)
        // A beat later the host has cleared it. hasText stays true because
        // SwiftTerm-based hosts force it so hold-delete keeps repeating.
        XCTAssertEqual(verdict(after: "", tail: inserted, hasText: true), .unreadable)
        // A host that genuinely re-rendered our text away still reads as a
        // failure: it reports a document, and ours is not in it.
        XCTAssertEqual(verdict(after: "unrelated text", tail: inserted,
                               hasText: true), .notAtCursor)
    }

    func testDeliveryRecordKeepsOneVerdictPerDictation() {
        let id = UUID()
        store.record(FlowDelivery(id: id, verdict: .notAtCursor, at: 1))
        XCTAssertEqual(store.deliveries.map(\.verdict), [.notAtCursor])
        // Re-inserting from the pill replaces the verdict, never stacks it.
        store.record(FlowDelivery(id: id, verdict: .landed, at: 2))
        XCTAssertEqual(store.deliveries.map(\.verdict), [.landed])
        XCTAssertFalse(InsertVerdict.notAtCursor.isDelivered)
        XCTAssertFalse(InsertVerdict.reverted.isDelivered)
        XCTAssertTrue(InsertVerdict.landedUnverifiable.isDelivered)
        store.clearResults()
        XCTAssertTrue(store.deliveries.isEmpty)
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

/// Drops the first N reads, then behaves. A keychain round trip can fail
/// once for reasons that have nothing to do with the channel being broken.
final class FlakyBackend: FlowBackend {
    private var storage: [String: Data] = [:]
    var dropReads = 0
    private(set) var reads = 0
    func data(forKey key: String) -> Data? {
        reads += 1
        if reads <= dropReads { return nil }
        return storage[key]
    }
    func set(_ data: Data, forKey key: String) { storage[key] = data }
    func removeValue(forKey key: String) { storage[key] = nil }
    func keys(withPrefix prefix: String) -> [String] {
        storage.keys.filter { $0.hasPrefix(prefix) }
    }
}

final class IPCProbeTests: XCTestCase {
    /// The probe is one write and one read of one key, as it was before I
    /// started rewriting it. Retries and per-attempt key names were
    /// guesses at a failure I never explained, and they rode on top of
    /// primitives I had also changed — so they could not be evaluated.
    func testAWorkingChannelCostsOneRoundTrip() {
        let flaky = FlakyBackend()
        XCTAssertTrue(FlowStore(backend: flaky).isAvailable)
        XCTAssertEqual(flaky.reads, 1)
    }

    func testABrokenChannelIsReported() {
        let flaky = FlakyBackend()
        flaky.dropReads = 99
        XCTAssertFalse(FlowStore(backend: flaky).isAvailable)
    }

    /// One key refusing to round-trip while every other key works — which
    /// is what the device reported. The probe says no; the app's heartbeat
    /// arriving here says yes, and it is the thing the probe only ever
    /// stood in for, so it wins.
    final class JammedProbeBackend: FlowBackend {
        private var storage: [String: Data] = [:]
        func data(forKey key: String) -> Data? {
            key == "flow.probe" ? nil : storage[key]
        }
        func set(_ data: Data, forKey key: String) { storage[key] = data }
        func removeValue(forKey key: String) { storage[key] = nil }
        func keys(withPrefix prefix: String) -> [String] {
            storage.keys.filter { $0.hasPrefix(prefix) }
        }
    }

    func testAFreshHeartbeatProvesTheChannelWhateverTheProbeSays() {
        let store = FlowStore(backend: JammedProbeBackend())
        store.heartbeat = Date()
        XCTAssertFalse(store.isAvailable, "the probe key is jammed")
        XCTAssertTrue(store.ipcProven, "but the app is demonstrably being heard")
    }
}
