import Foundation
import llama

/// Experimental dictation engine: Gemma 4 E2B (audio-in LLM) via llama.cpp.
///
/// Why it exists: an instruction-following model does what Whisper's broken
/// prompt path never could — punctuated Chinese, style through the whole
/// text, custom phrasing — and Mac validation showed verbatim discipline
/// (it even keeps 啊/呢 particles Whisper drops). Trade-offs: ~4.1 GB of
/// weights, GPU instead of Neural Engine, and a "thinking" preamble that
/// must be parsed away (and paid for in decode time).
/// Cross-isolation abort switch: settable while the actor is busy inside
/// a decode loop (an actor message couldn't be processed until too late).
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Stage breadcrumb readable while the actor is busy computing — the whole
/// point is diagnosing a wedged engine, which an actor await cannot do.
final class DiagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "no attempt yet"
    func set(_ newValue: String) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

actor GemmaEngine {
    static let modelURL = URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf")!
    static let mmprojURL = URL(string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/mmproj-F16.gguf")!

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var mtmd: OpaquePointer?
    private(set) var isReady = false
    /// Stage-by-stage breadcrumb of the current/last transcription attempt,
    /// surfaced in the app — readable even mid-compute.
    nonisolated let diag = DiagBox()
    /// Ending a session aborts in-flight decode within one token.
    nonisolated let abortFlag = AbortFlag()
    private let onState: @Sendable (Transcriber.State) -> Void

    init(onState: @escaping @Sendable (Transcriber.State) -> Void) {
        self.onState = onState
    }

    private static var modelDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gemma4", isDirectory: true)
    }

    // MARK: download

    /// Streams both GGUF files into Documents/gemma4 with combined progress
    /// (weights are ~75% of the bytes).
    private func ensureFiles() async throws -> (model: URL, mmproj: URL) {
        let dir = Self.modelDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let modelPath = dir.appendingPathComponent("model.gguf")
        let mmprojPath = dir.appendingPathComponent("mmproj.gguf")
        try await download(Self.modelURL, to: modelPath, share: 0.75, base: 0)
        try await download(Self.mmprojURL, to: mmprojPath, share: 0.25, base: 0.75)
        return (modelPath, mmprojPath)
    }

    private func download(_ url: URL, to destination: URL, share: Double, base: Double) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let partial = destination.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
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
                    onState(.downloading(base + share * min(1, written / max(total, 1))))
                }
            }
        }
        try handle.write(contentsOf: chunk)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    // MARK: lifecycle

    func load() async {
        guard !isReady else {
            onState(.ready)
            return
        }
        do {
            onState(.downloading(0))
            let files = try await ensureFiles()
            let modelBytes = (try? FileManager.default.attributesOfItem(atPath: files.model.path)[.size] as? Int) ?? 0
            let mmprojBytes = (try? FileManager.default.attributesOfItem(atPath: files.mmproj.path)[.size] as? Int) ?? 0
            diag.set("files: model=\(modelBytes ?? 0)B mmproj=\(mmprojBytes ?? 0)B")
            onState(.loading)

            llama_backend_init()
            var modelParams = llama_model_default_params()
            // CPU-ONLY, deliberately: keyboard dictations run while the app
            // is BACKGROUNDED, and iOS rejects GPU work from backgrounded
            // apps (Metal command buffers fail → eval -3 → empty text).
            // Whisper is immune because the ANE is background-allowed. CPU
            // decode of E2B Q4 is slower but works everywhere.
            modelParams.n_gpu_layers = 0
            guard let model = llama_model_load_from_file(files.model.path, modelParams) else {
                throw NSError(domain: "Gemma", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Gemma weights failed to load"])
            }
            self.model = model

            var ctxParams = llama_context_default_params()
            ctxParams.n_ctx = 4096
            ctxParams.n_threads = 6
            ctxParams.n_threads_batch = 6
            // Headroom, not a hard requirement: audio is ~25 tok/s and the
            // mtmd helper splits eval across batches itself (34 s passed at
            // 1024 on the Mac harness). The device -3 once blamed on batch
            // overflow was the background-Metal failure. 2048 keeps any
            // window we'd realistically feed in one comfortable batch.
            ctxParams.n_batch = 2048
            guard let context = llama_init_from_model(model, ctxParams) else {
                throw NSError(domain: "Gemma", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Gemma context failed"])
            }
            self.context = context

            var mtmdParams = mtmd_context_params_default()
            mtmdParams.use_gpu = false
            mtmdParams.print_timings = false
            mtmdParams.n_threads = 4
            mtmdParams.batch_max_tokens = 2048
            guard let mtmd = mtmd_init_from_file(files.mmproj.path, model, mtmdParams) else {
                throw NSError(domain: "Gemma", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Audio projector failed to load"])
            }
            self.mtmd = mtmd
            guard mtmd_support_audio(mtmd) else {
                throw NSError(domain: "Gemma", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "This mmproj has no audio support"])
            }
            isReady = true
            onState(.ready)
        } catch {
            unload()
            onState(.failed(error.localizedDescription))
        }
    }

    func unload() {
        if let mtmd { mtmd_free(mtmd) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        mtmd = nil
        context = nil
        model = nil
        isReady = false
        onState(.unloaded)
    }

    // MARK: transcription

    /// Instruction per language/tone — in the language of the dictation:
    /// Mac validation showed Chinese punctuation only lands when the
    /// instruction itself is Chinese.
    static func instruction(language: String?, tone: FlowTone) -> String {
        if language == "zh" {
            let base = "请逐字转写这段音频，使用标点符号。"
            let style: String
            switch tone {
            case .formal: style = ""
            case .casual: style = "语气自然随意。"
            case .veryCasual: style = "语气非常随意，像聊天消息。"
            case .excited: style = "语气兴奋，适当使用感叹号！"
            }
            return base + style + "只输出转写文本，不要任何解释。"
        }
        let base = "Transcribe this audio verbatim."
        let style: String
        switch tone {
        case .formal: style = " Use proper capitalization and punctuation."
        case .casual: style = " Write it naturally, casual register."
        case .veryCasual: style = " Write it like a casual text message: all lowercase, minimal punctuation."
        case .excited: style = " Write it with enthusiastic, excited punctuation!"
        }
        return base + style + " Output only the transcription, nothing else."
    }

    func transcribe(_ samples: [Float], language: String?, tone: FlowTone,
                    thinking: Bool = false, thinkingBudget: Int = 0) throws -> String {
        guard isReady, let context, let mtmd, let model else {
            throw NSError(domain: "Gemma", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Gemma not loaded"])
        }
        guard samples.count >= 8000 else { return "" }
        if abortFlag.get() { return "" }

        // Fresh conversation per dictation.
        llama_memory_clear(llama_get_memory(context), true)

        let marker = String(cString: mtmd_default_marker())
        // Gemma 4's template is NOT Gemma 3's <start_of_turn> — it uses
        // <|turn>…<turn|> markers (ground truth: the GGUF's own jinja
        // template rendered for one user turn). The wrong markers made the
        // model EOG instantly — every dictation came back empty. BOS is
        // added by tokenize (add_special), not written here. And do NOT
        // prefill an empty thought block — tried, also breaks generation.
        // thinking=true opens the thought channel the model natively uses
        // (observed verbatim in its own output), inviting a reasoning pass
        // before the answer; stripThinking() extracts the answer either way.
        let prompt = "<|turn>user\n"
            + Self.instruction(language: language, tone: tone)
            + " " + marker + "<turn|>\n<|turn>model\n"
            + (thinking ? "<|channel>thought\n" : "")

        guard let bitmap = samples.withUnsafeBufferPointer({
            mtmd_bitmap_init_from_audio(samples.count, $0.baseAddress)
        }) else {
            throw NSError(domain: "Gemma", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Audio buffer rejected"])
        }
        defer { mtmd_bitmap_free(bitmap) }

        guard let chunks = mtmd_input_chunks_init() else {
            throw NSError(domain: "Gemma", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Chunk allocation failed"])
        }
        defer { mtmd_input_chunks_free(chunks) }

        let tokenizeResult: Int32 = prompt.withCString { cPrompt in
            var text = mtmd_input_text(text: cPrompt,
                                       text_len: strlen(cPrompt),
                                       add_special: true,
                                       parse_special: true)
            var bitmapPtr: OpaquePointer? = bitmap
            return withUnsafeMutablePointer(to: &bitmapPtr) { bp in
                mtmd_tokenize(mtmd, chunks, &text, bp, 1)
            }
        }
        guard tokenizeResult == 0 else {
            diag.set("tokenize failed (\(tokenizeResult))")
            throw NSError(domain: "Gemma", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "Tokenize failed (\(tokenizeResult))"])
        }

        diag.set("audio eval running (\(samples.count) samples)…")
        var nPast: llama_pos = 0
        let evalResult = mtmd_helper_eval_chunks(mtmd, context, chunks, 0, 0, 2048, true, &nPast)
        guard evalResult == 0 else {
            diag.set("audio eval failed (\(evalResult))")
            throw NSError(domain: "Gemma", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "Audio evaluation failed (\(evalResult))"])
        }

        let vocab = llama_model_get_vocab(model)
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        defer { llama_sampler_free(sampler) }

        diag.set("decoding (n_past=\(nPast))…")
        // Thinking budget: the thought channel closes with a single special
        // token ("<channel|>"); once the cap is hit we feed that closer
        // ourselves so the model stops reasoning and answers — the same trick
        // as llama.cpp's --reasoning-budget. Harness-validated: forced-close
        // answers matched unlimited-thinking answers on en and zh audio,
        // and the ~170-token thought preamble is checklist boilerplate.
        let closerText = "<channel|>"
        var closerTokens = [llama_token](repeating: 0, count: 8)
        let nCloser = closerText.withCString { c in
            llama_tokenize(vocab, c, Int32(strlen(c)), &closerTokens, 8, false, true)
        }
        var inThought = thinking
        var thoughtTokens = 0
        var thoughtCapped = false

        var bytes: [UInt8] = []
        var pieceBuf = [CChar](repeating: 0, count: 256)
        for _ in 0..<700 {
            if abortFlag.get() {
                diag.set("aborted by session end")
                return ""
            }
            if inThought, thinkingBudget > 0, thoughtTokens >= thinkingBudget, nCloser > 0 {
                var forced = Array(closerTokens.prefix(Int(nCloser)))
                let closed = forced.withUnsafeMutableBufferPointer { p -> Bool in
                    let batch = llama_batch_get_one(p.baseAddress, Int32(p.count))
                    return llama_decode(context, batch) == 0
                }
                guard closed else { break }
                bytes.append(contentsOf: Array(closerText.utf8))
                inThought = false
                thoughtCapped = true
            }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let n = llama_token_to_piece(vocab, token, &pieceBuf, 256, 0, true)
            if n > 0 {
                pieceBuf.withUnsafeBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: Int(n)) {
                        bytes.append(contentsOf: UnsafeBufferPointer(start: $0, count: Int(n)))
                    }
                }
            }
            if inThought {
                thoughtTokens += 1
                if (nCloser == 1 && token == closerTokens[0])
                    || String(decoding: bytes, as: UTF8.self).hasSuffix(closerText) {
                    inThought = false
                }
            }
            let batch = llama_batch_get_one(&token, 1)
            guard llama_decode(context, batch) == 0 else { break }
        }

        let raw = String(decoding: bytes, as: UTF8.self)
        let stripped = Self.stripThinking(raw)
        diag.set("done: n_past=\(nPast), \(bytes.count) bytes, "
            + "thought=\(thoughtTokens)\(thoughtCapped ? " capped" : ""), raw='\(raw.prefix(120))'")
        return stripped
    }

    /// E2B emits "<|channel>thought …reasoning… <channel|>answer" — keep
    /// only the answer. Unit-tested.
    static func stripThinking(_ raw: String) -> String {
        var text = raw
        if let range = text.range(of: "<channel|>", options: .backwards) {
            text = String(text[range.upperBound...])
        }
        text = text.replacingOccurrences(of: "<end_of_turn>", with: "")
        text = text.replacingOccurrences(of: "<turn|>", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
