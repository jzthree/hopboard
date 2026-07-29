import Foundation
import WhisperKit

/// Thin wrapper around WhisperKit. Two models:
/// - turbo (626 MB): Argmax's recommended iPhone build of large-v3-turbo.
///   Fast, but its distilled 4-layer decoder cannot take prompts at all
///   (deterministically empty output — measured).
/// - accurate (947 MB compressed large-v3): slower, but prompts mostly
///   work, which is the only known lever for Chinese punctuation. "Mostly":
///   some prompt texts still collapse to empty (measured 2/4), so every
///   prompted decode carries an automatic promptless retry.
actor Transcriber {
    static let turboModel = "large-v3-v20240930_626MB"
    static let accurateModel = "large-v3_947MB"
    /// The fix for Whisper's Chinese no-punctuation mode. CRITICAL: the
    /// prompt must read like transcript text. Instruction-style prompts
    /// ("请使用标点符号") derail real Chinese audio into subtitle-outro
    /// hallucinations ("请不吝点赞 订阅…") — measured on Aishell speech;
    /// this neutral sentence was one of 4/6 that reliably punctuated it.
    static let zhPunctuationPrompt = "以下是普通话的句子。"

    enum State: Equatable {
        case unloaded
        case downloading(Double)   // 0...1
        case loading               // prewarm / specialize on the ANE
        case ready
        case failed(String)
    }

    private var pipe: WhisperKit?
    private(set) var state: State = .unloaded
    private(set) var loadedModel: String?
    private let onState: @Sendable (State) -> Void

    init(onState: @escaping @Sendable (State) -> Void) {
        self.onState = onState
    }

    private func set(_ new: State) {
        state = new
        onState(new)
    }

    /// Download callbacks keep firing at 100% during file verification and
    /// can land AFTER the state moved on to .loading — without this guard
    /// the UI shows a progress bar stuck at 100% for the whole Neural
    /// Engine compile.
    private func applyDownloadProgress(_ fraction: Double) {
        if case .downloading = state {
            set(.downloading(fraction))
        }
    }

    var isReady: Bool { pipe != nil }

    func load(model: String) async {
        if pipe != nil, loadedModel == model {
            set(.ready)
            return
        }
        pipe = nil
        loadedModel = model
        do {
            set(.downloading(0))
            let folder = try await WhisperKit.download(
                variant: model,
                progressCallback: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { await self?.applyDownloadProgress(fraction) }
                })
            set(.loading)
            let config = WhisperKitConfig(
                model: model,
                modelFolder: folder.path,
                prewarm: true,
                load: true,
                download: false)
            pipe = try await WhisperKit(config)
            set(.ready)
        } catch {
            set(.failed(error.localizedDescription))
        }
    }

    /// Transcribes 16 kHz mono samples. Returns trimmed text ("" if silence).
    /// `language` is a whisper code ("en", "zh", …); nil or "auto" detects.
    ///
    /// Deliberately NO promptTokens: in WhisperKit 1.x a prompt with
    /// prefill makes the decoder emit <|endoftext|> immediately (empty
    /// transcription — this broke every dictation), and without prefill the
    /// prompt is ignored entirely. Both proven against real speech in
    /// scripts/wktest notes; tone styling is post-processing (FlowTone).
    func transcribe(_ samples: [Float], language: String? = nil) async throws -> String {
        guard let pipe else {
            throw NSError(domain: "FlowBoard", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        // Whisper hallucinates on sub-second clips; treat them as silence.
        guard samples.count >= Int(AudioRecorder.targetSampleRate / 2) else { return "" }
        // Energy gate: near-digital-silence makes Whisper hallucinate
        // ("Thank you." — reproduced in the sim autotest) and burns a full
        // inference pass. A real mic's noise floor sits well above this.
        var energy: Float = 0
        for sample in samples { energy += sample * sample }
        let rms = (energy / Float(samples.count)).squareRoot()
        guard rms > 0.0005 else { return "" }
        var options = DecodingOptions()
        if let language, language != "auto" {
            options.language = language
        } else {
            options.detectLanguage = true
        }

        // Chinese on the accurate model: attempt the punctuation prompt
        // with the no-speech filters relaxed (they misfire on prompted
        // decodes). If the prompt flake strikes and the result is empty,
        // fall through to a plain decode — never worse than turbo behavior.
        if loadedModel == Self.accurateModel, language == "zh",
           let tokenizer = pipe.tokenizer {
            var prompted = options
            prompted.promptTokens = tokenizer.encode(text: " " + Self.zhPunctuationPrompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            prompted.usePrefillPrompt = true
            prompted.firstTokenLogProbThreshold = -1e9
            prompted.logProbThreshold = -1e9
            prompted.noSpeechThreshold = 1.0
            let promptedResults = try await pipe.transcribe(audioArray: samples, decodeOptions: prompted)
            let promptedText = promptedResults.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !promptedText.isEmpty { return promptedText }
        }

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        pipe = nil
        set(.unloaded)
    }
}
