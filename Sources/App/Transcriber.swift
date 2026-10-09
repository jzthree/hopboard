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
    /// Where both variants come from — and, once fetched, where they live
    /// under Documents/huggingface/models.
    static let modelRepo = "argmaxinc/whisperkit-coreml"
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

    /// True once this model has fully loaded under this app build — i.e.
    /// the slow one-time Neural Engine specialization is behind us and
    /// future loads are plain (fast) loads.
    static func hasOptimized(_ model: String) -> Bool {
        UserDefaults.standard.bool(forKey: optimizedKey(model))
    }

    private static func optimizedKey(_ model: String) -> String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "flow.aneOptimized.\(model).\(build)"
    }

    /// Where WhisperKit's downloader puts a variant, if it is already fully
    /// there. Worth finding ourselves: `WhisperKit.download` ALWAYS lists
    /// the repo over the network first, even when every file is on disk,
    /// and then reports per-file progress while it re-checks them — so a
    /// launch with the weights already present announced "Downloading" and
    /// counted its way up for nothing. Going straight to the folder skips
    /// the round-trip, and the tokenizer ships inside it, so a cached model
    /// no longer needs the network to load.
    static func cachedModelFolder(for model: String) -> URL? {
        let root = HubApiWrapper().localRepoLocation(HubApiWrapper.Repo(id: modelRepo))
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return nil }
        // Folders are named for the variant with a prefix
        // ("openai_whisper-large-v3-v20240930_626MB") — the same match
        // download() makes against the remote listing.
        guard let folder = entries.first(where: { $0.lastPathComponent.contains(model) })
        else { return nil }
        // An interrupted download leaves the folder behind with pieces
        // missing; WhisperKit would throw on load and the app would report
        // a broken model. Treat incomplete as absent and let download()
        // repair it — these are the three bundles loadModels requires.
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy {
            FileManager.default.fileExists(
                atPath: ModelUtilities.detectModelURL(inFolder: folder, named: $0).path)
        } ? folder : nil
    }

    func load(model: String) async {
        if pipe != nil, loadedModel == model {
            set(.ready)
            return
        }
        pipe = nil
        loadedModel = model

        // What is already on disk gets the first try — but only a try.
        // cachedModelFolder asks whether three bundles EXIST, and a
        // download interrupted inside one of them leaves all three present
        // and one of them hollow. That loaded as a hard failure which could
        // never recover: the next attempt made the same existence check,
        // skipped the download that would have repaired it, and failed
        // again, for good. Loading is the only real integrity check there
        // is, and the honest response to it failing is to go and fetch the
        // model again rather than to give up.
        if let cached = Self.cachedModelFolder(for: model) {
            set(.loading)
            if await attachPipe(from: cached, model: model) { return }
        }

        do {
            set(.downloading(0))
            let folder = try await WhisperKit.download(
                variant: model,
                progressCallback: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { await self?.applyDownloadProgress(fraction) }
                })
            set(.loading)
            if await attachPipe(from: folder, model: model) { return }
            // Downloaded and still unloadable: the files on disk are wrong
            // in a way re-fetching the missing ones cannot fix. Clear them
            // so the next attempt starts from nothing instead of inheriting
            // the same broken state forever.
            try? FileManager.default.removeItem(at: folder)
            set(.failed("The model is damaged. It has been cleared — start a session again to download it fresh."))
        } catch {
            set(.failed(error.localizedDescription))
        }
    }

    /// Returns false instead of throwing: at the first call site the
    /// caller's next move is to re-download, not to report a failure.
    private func attachPipe(from folder: URL, model: String) async -> Bool {
        do {
            let config = WhisperKitConfig(
                model: model,
                modelFolder: folder.path,
                prewarm: true,
                load: true,
                download: false)
            pipe = try await WhisperKit(config)
            UserDefaults.standard.set(true, forKey: Self.optimizedKey(model))
            set(.ready)
            return true
        } catch {
            pipe = nil
            return false
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
    /// `temperature` 0 is greedy and DETERMINISTIC — the same audio decodes
    /// to the same text every time, which is why "just run it again" needs
    /// a nonzero value to be anything but a no-op. Whisper's own remedy for
    /// a decode that came out wrong is exactly this fallback ladder.
    func transcribe(_ samples: [Float], language: String? = nil,
                    temperature: Float = 0) async throws -> String {
        guard let pipe else {
            throw NSError(domain: "HopBoard", code: 2,
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
        options.temperature = temperature
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
