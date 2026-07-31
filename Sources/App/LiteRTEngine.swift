import Foundation
import LiteRTLM

/// The in-flight conversation, reachable from OUTSIDE the actor so ending a
/// session can cancel mid-generation — cancel() is a thread-safe C call
/// designed for exactly this (same rationale as AbortFlag on the llama path,
/// where an actor message couldn't be processed until too late).
final class ConversationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Conversation?
    func set(_ conversation: Conversation?) {
        lock.lock(); value = conversation; lock.unlock()
    }
    func cancelLive() {
        lock.lock(); let live = value; lock.unlock()
        try? live?.cancel()
    }
}

/// Experimental dictation engine: the SAME Gemma 4 E2B as GemmaEngine, but
/// through Google's official LiteRT-LM runtime — for an accuracy A/B.
///
/// Why it exists: the official .litertlm is quantization-aware trained
/// (2/4/8-bit mix, 2.6 GB single file) versus the llama.cpp path's post-hoc
/// Q4_K_M GGUF (4.1 GB with mmproj), and QAT is the configuration Gemma's
/// published accuracy numbers were measured on. Google's own iPhone 17 Pro
/// benchmark: 25 tok/s decode on CPU. CPU-only here for the same reason as
/// GemmaEngine: keyboard dictations run while the app is backgrounded, and
/// iOS forbids Metal there. The runtime applies Gemma's chat template
/// itself, so no <|turn> assembly on our side; thinking and its budget map
/// onto the runtime's own ThinkingConfig.
actor LiteRTEngine {
    /// Official QAT builds: E2B (fast) and E4B (more accurate, both with
    /// audio models included). Bigger litert-community builds exist (12B =
    /// 6.5 GB) but their model cards target macOS/linux/web, and a
    /// backgrounded iOS app holding 6.5 GB would be jetsam-killed — E4B is
    /// the on-phone ceiling.
    static func modelURL(variant: String) -> URL {
        let name = variant == "e4b" ? "gemma-4-E4B-it" : "gemma-4-E2B-it"
        return URL(string: "https://huggingface.co/litert-community/\(name)-litert-lm/resolve/main/\(name).litertlm")!
    }

    private var engine: LiteRTLM.Engine?
    private(set) var isReady = false
    private var loadedVariant: String?
    /// Stage-by-stage breadcrumb of the current/last transcription attempt,
    /// readable even mid-compute.
    nonisolated let diag = DiagBox()
    /// Ending a session: reject new work and cancel in-flight generation.
    nonisolated let abortFlag = AbortFlag()
    private nonisolated let live = ConversationBox()
    private let onState: @Sendable (Transcriber.State) -> Void

    init(onState: @escaping @Sendable (Transcriber.State) -> Void) {
        self.onState = onState
    }

    /// One call for endSession: no new transcriptions start, and the one
    /// running right now stops generating.
    nonisolated func abort() {
        abortFlag.set(true)
        live.cancelLive()
    }

    private static func modelPath(variant: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("litertlm", isDirectory: true)
            .appendingPathComponent("model-\(variant).litertlm")
    }

    // MARK: download

    private func ensureFile(variant: String) async throws -> URL {
        let destination = Self.modelPath(variant: variant)
        // The first shipped build stored E2B as plain model.litertlm —
        // adopt it rather than re-downloading 2.6 GB.
        let legacy = destination.deletingLastPathComponent()
            .appendingPathComponent("model.litertlm")
        if variant == "e2b", FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.moveItem(at: legacy, to: destination)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { return destination }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        let (bytes, response) = try await URLSession.shared.bytes(from: Self.modelURL(variant: variant))
        let total = Double(response.expectedContentLength)
        var written: Double = 0
        var chunk = Data(capacity: 1 << 20)
        var lastReport = Date.distantPast
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 1 << 20 {
                try handle.write(contentsOf: chunk)
                written += Double(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                if Date().timeIntervalSince(lastReport) > 0.5 {
                    lastReport = Date()
                    onState(.downloading(min(1, written / max(total, 1))))
                }
            }
        }
        try handle.write(contentsOf: chunk)
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    // MARK: lifecycle

    func load(variant: String) async {
        guard !(isReady && loadedVariant == variant) else {
            onState(.ready)
            return
        }
        // Size switch: free the old engine before standing up the new one.
        if isReady { unload() }
        do {
            onState(.downloading(0))
            let modelFile = try await ensureFile(variant: variant)
            let modelBytes = (try? FileManager.default.attributesOfItem(atPath: modelFile.path)[.size] as? Int) ?? 0
            diag.set("file: \(modelBytes ?? 0)B")
            onState(.loading)

            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("litertlm-cache", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            // CPU for both the LLM and the audio encoder — see the type
            // comment; the background-Metal ban applies to every runtime.
            let config = try EngineConfig(
                modelPath: modelFile.path,
                backend: .cpu(threadCount: 6),
                audioBackend: .cpu(),
                maxNumTokens: 4096,
                cacheDir: cache.path)
            let engine = LiteRTLM.Engine(engineConfig: config)
            diag.set("initializing engine…")
            try await engine.initialize()
            self.engine = engine
            isReady = true
            loadedVariant = variant
            onState(.ready)
        } catch {
            engine = nil
            isReady = false
            loadedVariant = nil
            onState(.failed(error.localizedDescription))
        }
    }

    func unload() {
        engine = nil
        isReady = false
        loadedVariant = nil
        onState(.unloaded)
    }

    // MARK: transcription

    // No thinking/budget knobs here: the v0.14.0 binaries predate the
    // thinking C API (zero thinking symbols in the shipped headers), so the
    // runtime's own default governs. The thought never pollutes the text —
    // it lives in the response's channels, and toString is contents-only.
    // Wire ThinkingConfig through when upstream ships newer binaries.
    func transcribe(_ samples: [Float], language: String?, tone: FlowTone,
                    customInstruction: String? = nil) async throws -> String {
        guard isReady, let engine else {
            throw NSError(domain: "LiteRT", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "LiteRT not loaded"])
        }
        guard samples.count >= 8000 else { return "" }
        if abortFlag.get() { return "" }

        // Fresh conversation per dictation window — clean context, the
        // analog of llama_memory_clear on the llama.cpp path.
        diag.set("creating conversation…")
        let conversation = try await engine.createConversation()
        live.set(conversation)
        defer { live.set(nil) }

        let instruction = customInstruction
            ?? GemmaEngine.instruction(language: language, tone: tone)
        let wav = Self.wavData(from: samples)
        diag.set("sendMessage running (\(samples.count) samples)…")
        let response = try await conversation.sendMessage(
            Message(of: .audioData(wav), .text(instruction)))
        if abortFlag.get() {
            diag.set("aborted by session end")
            return ""
        }
        // toString is text contents only — the thought stays in channels,
        // so there is nothing to strip.
        let text = response.toString.trimmingCharacters(in: .whitespacesAndNewlines)
        diag.set("done: '\(text.prefix(120))'")
        return text
    }

    /// Minimal 16 kHz mono PCM16 WAV container around the session's Float
    /// samples — Content.audioData wants a parseable audio blob, not raw
    /// PCM. Unit-tested.
    static func wavData(from samples: [Float], sampleRate: Int = 16000) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)                        // PCM
        append16(1)                        // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))   // byte rate
        append16(2)                        // block align
        append16(16)                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            append16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }
}
