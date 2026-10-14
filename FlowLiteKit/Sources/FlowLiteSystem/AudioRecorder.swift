import AVFoundation
import FlowLiteCore

public enum RecorderError: Error {
    case noInputDevice
}

/// Captures the default input device as 16 kHz mono Float32. The engine starts on the first
/// `start()` and stops after 60 s without use, so the mic indicator isn't permanently on.
public final class AudioRecorder: AudioRecording {
    /// Meter level 0...1, delivered on the main thread while capturing.
    public var onLevel: ((Float) -> Void)?

    static let maxSamples = Int(AudioMath.sampleRate) * 300   // 5 minutes
    static let idleStopSeconds: TimeInterval = 60

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioMath.sampleRate,
                                             channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false
    private var idleTimer: Timer?
    private var configObserver: NSObjectProtocol?

    public init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    public func start() throws {
        idleTimer?.invalidate()
        try startEngineIfNeeded()
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            capturing = true
        }
    }

    public func stop() -> RecordedAudio {
        let captured: [Float] = lock.withLock {
            capturing = false
            return samples
        }
        scheduleIdleStop()
        return RecordedAudio(samples: captured)
    }

    public func cancel() {
        lock.withLock {
            capturing = false
            samples.removeAll()
        }
        scheduleIdleStop()
    }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noInputDevice }
        input.removeTap(onBus: 0)
        // The converter lives only in the tap (one audio thread) and follows the buffers' actual format.
        var converter: AVAudioConverter?
        let targetFormat = self.targetFormat
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            if converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            }
            guard let converter else { return }
            self?.process(buffer, converter: converter)
        }
        engine.prepare()
        try engine.start()
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        guard lock.withLock({ capturing }) else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))

        lock.withLock {
            if capturing, samples.count < Self.maxSamples { samples.append(contentsOf: chunk) }
        }
        let level = AudioMath.meterLevel(rms: AudioMath.rms(chunk))
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    private func scheduleIdleStop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleStopSeconds, repeats: false) { [weak self] _ in
                guard let self, !lock.withLock({ self.capturing }) else { return }
                engine.stop()
            }
        }
    }

    /// The default input device changed (e.g. AirPods connected); rebuild the tap for the new format.
    private func handleConfigurationChange() {
        let wasCapturing = lock.withLock { capturing }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if wasCapturing { try? startEngineIfNeeded() }
    }
}
