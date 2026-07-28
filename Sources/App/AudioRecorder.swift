import AVFoundation

/// Owns the AVAudioEngine for the lifetime of a Flow Session. The engine
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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: session)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1, interleaved: false) else {
            throw NSError(domain: "FlowBoard", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create 16 kHz format"])
        }
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer, outputFormat: outputFormat)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        // Hard cap: 4 minutes of 16 kHz mono (~15 MB). A runaway segment
        // should degrade to "truncated", never to an OOM kill mid-session.
        if samples.count < Int(Self.targetSampleRate) * 240 {
            samples.append(contentsOf: chunk)
        }
        lock.unlock()

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
