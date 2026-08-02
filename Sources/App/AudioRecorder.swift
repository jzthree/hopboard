import AVFoundation

/// Owns the AVAudioEngine for the lifetime of a Session. The engine
/// runs continuously — an active audio I/O session is what keeps the app
/// alive in the background (UIBackgroundModes: audio); samples are only
/// buffered between beginSegment/takeSegment.
final class AudioRecorder {
    static let targetSampleRate: Double = 16_000  // what Whisper expects

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var capturing = false
    private var samples: [Float] = []

    /// Called on the audio thread at ~5 Hz with an RMS level in 0...1,
    /// only while a segment is being captured.
    var onLevel: ((Float) -> Void)?
    /// Called on the main thread when the session is interrupted (call,
    /// Siri, another app taking the mic) and cannot continue.
    var onInterruption: (() -> Void)?
    /// Called on the audio thread each time a completed ~30 s window rolls
    /// out of a long dictation, so transcription can start while the user
    /// is still talking. The window is removed from the buffer — the
    /// callee owns (and should discard) it after transcribing.
    var onWindow: (([Float]) -> Void)?

    /// Long dictations roll out in windows, cut at the quietest 200 ms in
    /// the last few seconds to avoid splitting mid-word. 30 s is Whisper's
    /// native span; Gemma's audio encoder needs shorter chunks (12 s) to
    /// stay inside device batch limits — set per session.
    var windowSeconds = 30
    static let windowSearchFrames = Int(targetSampleRate) * 5

    /// Apple's voice-processing I/O unit: echo cancellation, noise
    /// suppression and automatic gain — the same front-end system dictation
    /// uses. Quiet or far-field speech reaches the model at a usable level
    /// instead of being transcribed as a guess. Set before start().
    var voiceProcessing = true

    /// Whether the running engine actually got the voice-processing unit —
    /// it can refuse depending on route and graph, and the UI shouldn't
    /// claim mic modes that aren't in play. (Declared outside the device
    /// branch so simulator builds — the test host — still compile.)
    private(set) var usingVoiceProcessing = false

    var windowFrames: Int { Int(Self.targetSampleRate) * windowSeconds }

    /// The quietest cut point inside the search region at the end of a
    /// full window. Pure function, unit-tested.
    static func quietCutIndex(in samples: [Float], windowFrames: Int) -> Int {
        let end = min(windowFrames, samples.count)
        let hop = Int(targetSampleRate) / 5  // 200 ms
        var best = end
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = max(0, end - windowSearchFrames)
        while i + hop <= end {
            var energy: Float = 0
            for j in i..<(i + hop) { energy += samples[j] * samples[j] }
            if energy < bestEnergy {
                bestEnergy = energy
                best = i + hop / 2
            }
            i += hop
        }
        return best
    }

    private var levelThrottle = 0

    // The simulator's AURemoteIO aborts with an uncatchable RPC timeout on
    // inputNode access (host CoreAudio hang, reproduced twice), so the sim
    // build never touches the engine: segments return synthetic silence,
    // which still drives the full Whisper pipeline end-to-end.
    #if targetEnvironment(simulator)
    private var simRunning = false
    private var simSegmentStart: Date?

    var isRunning: Bool { simRunning }

    func start() throws {
        simRunning = true
    }

    func stop() {
        simRunning = false
        simSegmentStart = nil
    }

    func beginSegment() {
        simSegmentStart = Date()
        onLevel?(0.3)
    }

    func cancelSegment() {
        simSegmentStart = nil
    }

    func takeSegment() -> [Float] {
        guard let start = simSegmentStart else { return [] }
        simSegmentStart = nil
        let frames = Int(Date().timeIntervalSince(start) * Self.targetSampleRate)
        return [Float](repeating: 0, count: min(frames, Int(Self.targetSampleRate) * 240))
    }
    #else
    var isRunning: Bool { engine.isRunning }

    func start() throws {
        do {
            try startEngine(withVoiceProcessing: voiceProcessing)
        } catch {
            // A microphone that starts plain beats a session that refuses to
            // start at all: the voice-processing unit declines on some
            // routes (and takes the whole graph down with it), which is a
            // failure the user experiences as "cannot start mic".
            guard voiceProcessing else { throw error }
            teardownEngine()
            try startEngine(withVoiceProcessing: false)
        }
    }

    private func startEngine(withVoiceProcessing enable: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // .voiceChat is the mode the voice-processing unit expects; plain
        // capture keeps the long-standing .default configuration.
        try session.setCategory(.playAndRecord,
                                mode: enable ? .voiceChat : .default,
                                options: [.mixWithOthers])
        try session.setActive(true)

        NotificationCenter.default.removeObserver(
            self, name: AVAudioSession.interruptionNotification, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: session)

        let input = engine.inputNode
        // Must precede reading the format — toggling it reconfigures the
        // node and changes its output format.
        if input.isVoiceProcessingEnabled != enable {
            try input.setVoiceProcessingEnabled(enable)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        // A zero-rate format means the route isn't ready; installing a tap
        // with it raises rather than throws, taking the app with it.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "HopBoard", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The microphone route is not ready"])
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw NSError(domain: "HopBoard", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create 16 kHz format"])
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer, outputFormat: outputFormat)
        }
        engine.prepare()
        try engine.start()
        usingVoiceProcessing = enable
    }

    private func teardownEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        usingVoiceProcessing = false
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock()
        capturing = false
        samples.removeAll()
        lock.unlock()
    }

    func beginSegment() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        capturing = true
        lock.unlock()
    }

    func cancelSegment() {
        lock.lock()
        capturing = false
        samples.removeAll()
        lock.unlock()
    }

    /// Ends the segment and returns everything captured since beginSegment.
    func takeSegment() -> [Float] {
        lock.lock()
        capturing = false
        let taken = samples
        samples = []
        lock.unlock()
        return taken
    }
    #endif

    private func consume(_ buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        lock.lock()
        let active = capturing
        lock.unlock()
        guard active, let converter else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = converted.floatChannelData else { return }

        let frames = Int(converted.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: frames))

        lock.lock()
        // Hard cap: 4 minutes of 16 kHz mono (~15 MB). Windows roll out
        // below, so this cap only ever applies to a pathological tail.
        if samples.count < Int(Self.targetSampleRate) * 240 {
            samples.append(contentsOf: chunk)
        }
        var window: [Float]?
        if capturing, samples.count >= windowFrames {
            let cut = Self.quietCutIndex(in: samples, windowFrames: windowFrames)
            window = Array(samples[0..<cut])
            samples.removeFirst(cut)
        }
        lock.unlock()
        if let window { onWindow?(window) }

        levelThrottle += 1
        if levelThrottle % 3 == 0, frames > 0 {
            var sum: Float = 0
            for i in 0..<frames { sum += chunk[i] * chunk[i] }
            let rms = (sum / Float(frames)).squareRoot()
            // Map speech-typical RMS (~0.01–0.3) onto 0...1 perceptually.
            let level = min(1, max(0, (log10(max(rms, 0.0001)) + 4) / 3.5))
            onLevel?(level)
        }
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            DispatchQueue.main.async { self.onInterruption?() }
        }
    }
}
