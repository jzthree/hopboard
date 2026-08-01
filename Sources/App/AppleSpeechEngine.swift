import AVFoundation
import Foundation
import Speech

/// Apple's iOS 26 SpeechTranscriber — the system model behind Notes and
/// Voice Memos live transcription, NOT the old keyboard-dictation stack
/// (that lineage is DictationTranscriber). Benchmarks put it ~4× lower WER
/// than the old dictation on the same audio, near Whisper-large accuracy at
/// several times the speed, with native punctuation including Chinese.
/// Runs on Apple's neural stack (background-safe like WhisperKit) and the
/// model is a system asset — nothing bundled, one system download per
/// language.
@available(iOS 26.0, *)
actor AppleSpeechEngine {
    private(set) var isReady = false
    private var readyLocaleID: String?
    /// Stage-by-stage breadcrumb of the current/last attempt.
    nonisolated let diag = DiagBox()
    /// Ending a session: reject transcriptions queued after the end.
    nonisolated let abortFlag = AbortFlag()
    private let onState: @Sendable (Transcriber.State) -> Void

    init(onState: @escaping @Sendable (Transcriber.State) -> Void) {
        self.onState = onState
    }

    /// Whisper language codes (the stored setting) → locales. "auto" means
    /// the device language: this engine has no cross-language detection —
    /// one transcriber is one locale.
    static func locale(for languageCode: String?) -> Locale {
        switch languageCode {
        case nil, "auto": Locale.current
        case "zh": Locale(identifier: "zh_CN")
        case "en": Locale(identifier: "en_US")
        case let code?: Locale(identifier: code)
        }
    }

    // MARK: lifecycle

    func load(language: String?) async {
        let locale = Self.locale(for: language)
        let localeID = locale.identifier(.bcp47)
        guard !(isReady && readyLocaleID == localeID) else {
            onState(.ready)
            return
        }
        do {
            diag.set("resolving locale \(localeID)…")
            let supported = await SpeechTranscriber.supportedLocales
            guard supported.contains(where: { $0.identifier(.bcp47) == localeID }) else {
                throw NSError(domain: "AppleSpeech", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Apple's transcriber does not support \(localeID) — pin a supported language."])
            }
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            let installed = await SpeechTranscriber.installedLocales
            if !installed.contains(where: { $0.identifier(.bcp47) == localeID }) {
                // Each app gets a small quota of reserved locales; switching
                // language without releasing the old reservation makes the
                // install request fail. Free everything but the target.
                for reserved in await AssetInventory.reservedLocales
                where reserved.identifier(.bcp47) != localeID {
                    _ = await AssetInventory.release(reservedLocale: reserved)
                }
                diag.set("downloading system model for \(localeID)…")
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]) {
                    let progress = request.progress
                    let poll = Task { [onState] in
                        while !Task.isCancelled {
                            onState(.downloading(progress.fractionCompleted))
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                    }
                    do {
                        try await request.downloadAndInstall()
                        poll.cancel()
                    } catch {
                        poll.cancel()
                        throw error
                    }
                }
            }
            onState(.loading)
            isReady = true
            readyLocaleID = localeID
            diag.set("ready (\(localeID))")
            onState(.ready)
        } catch {
            isReady = false
            readyLocaleID = nil
            onState(.failed(error.localizedDescription))
        }
    }

    func unload() {
        // The model is a system asset — nothing of ours to free.
        isReady = false
        readyLocaleID = nil
        onState(.unloaded)
    }

    // MARK: transcription

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        guard isReady else {
            throw NSError(domain: "AppleSpeech", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Apple engine not loaded"])
        }
        guard samples.count >= 8000 else { return "" }
        if abortFlag.get() { return "" }
        // Same energy gate as the Whisper path: a quiet window is a normal
        // non-event, not something to analyze (or to report as an error).
        var energy: Float = 0
        for sample in samples { energy += sample * sample }
        let rms = (energy / Float(samples.count)).squareRoot()
        guard rms > 0.0005 else {
            diag.set("skipped quiet window (rms \(rms))")
            return ""
        }

        let locale = Self.locale(for: language)
        // Modules are cheap to create; the heavy lifting is the system
        // asset, which is cached. One analyzer per window keeps every
        // window independent — the same isolation the other engines get
        // from a fresh conversation/context.
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        diag.set("preparing audio (\(samples.count) samples)…")
        guard let native = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: native,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "AppleSpeech", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Audio buffer allocation failed"])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        var analyzed = buffer
        if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
           best != native {
            analyzed = try Self.convert(buffer, to: best)
        }

        diag.set("analyzing…")
        let collect = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: analyzed))
        continuation.finish()
        try await analyzer.analyzeSequence(stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
        diag.set("done: '\(text.prefix(120))'")
        return text
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw NSError(domain: "AppleSpeech", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Audio converter unavailable"])
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw NSError(domain: "AppleSpeech", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Converted buffer allocation failed"])
        }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        return out
    }
}
