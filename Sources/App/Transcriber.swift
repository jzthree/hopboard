import Foundation
import WhisperKit

/// Thin wrapper around WhisperKit pinned to large-v3-turbo. The 626 MB
/// mixed-bit palettized variant is Argmax's recommended iPhone build of
/// large-v3-v20240930 (turbo) — near-lossless quality, ANE-friendly.
actor Transcriber {
    static let modelName = "large-v3-v20240930_626MB"

    enum State: Equatable {
        case unloaded
        case downloading(Double)   // 0...1
        case loading               // prewarm / specialize on the ANE
        case ready
        case failed(String)
    }

    private var pipe: WhisperKit?
    private(set) var state: State = .unloaded
    private let onState: @Sendable (State) -> Void

    init(onState: @escaping @Sendable (State) -> Void) {
        self.onState = onState
    }

    private func set(_ new: State) {
        state = new
        onState(new)
    }

    var isReady: Bool { pipe != nil }

    func load() async {
        guard pipe == nil else {
            set(.ready)
            return
        }
        do {
            set(.downloading(0))
            let folder = try await WhisperKit.download(
                variant: Self.modelName,
                progressCallback: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    Task { await self?.set(.downloading(fraction)) }
                })
            set(.loading)
            let config = WhisperKitConfig(
                model: Self.modelName,
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
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipe else {
            throw NSError(domain: "FlowBoard", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        // Whisper hallucinates on sub-second clips; treat them as silence.
        guard samples.count >= Int(AudioRecorder.targetSampleRate / 2) else { return "" }
        let results = try await pipe.transcribe(audioArray: samples)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        pipe = nil
        set(.unloaded)
    }
}
