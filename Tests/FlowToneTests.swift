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

final class LiteRTEngineTests: XCTestCase {
    func testWavData() {
        let wav = LiteRTEngine.wavData(from: [0, 0.5, -0.5, 1.5])
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        // Little-endian data-chunk size = 4 samples × 2 bytes.
        XCTAssertEqual(wav[40..<44], Data([8, 0, 0, 0]))
        // 16 kHz little-endian at offset 24.
        XCTAssertEqual(wav[24..<28], Data([0x80, 0x3E, 0, 0]))
        // Samples: 0, +half, -half, and 1.5 clamps to Int16.max.
        let pcm = wav.suffix(8).withUnsafeBytes { buf in
            (0..<4).map { Int16(littleEndian: buf.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
        }
        XCTAssertEqual(pcm[0], 0)
        XCTAssertEqual(pcm[1], 16383)
        XCTAssertEqual(pcm[2], -16383)
        XCTAssertEqual(pcm[3], 32767)
    }
}
