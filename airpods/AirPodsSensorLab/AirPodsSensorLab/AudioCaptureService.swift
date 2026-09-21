import AVFoundation
import Speech

final class AudioCaptureService {
    struct MeterReading {
        let rmsDBFS: Double
        let peakDBFS: Double
    }

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var tapInstalled = false
    private var lastBufferTime = ProcessInfo.processInfo.systemUptime

    static func requestPermissions() async -> Bool {
        let microphone = await AVAudioApplication.requestRecordPermission()
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return microphone && speech
    }

    func start(
        recordingURL: URL,
        onMeter: @escaping @Sendable (MeterReading) -> Void,
        onTranscript: @escaping @Sendable (_ text: String, _ isFinal: Bool, _ latencyMilliseconds: Double) -> Void
    ) throws -> AudioRouteSnapshot {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetooth, .defaultToSpeaker]
        if #available(iOS 26.0, *) {
            options.insert(.bluetoothHighQualityRecording)
        }
        try session.setCategory(.playAndRecord, mode: .measurement, options: options)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noAudioInput
        }

        audioFile = try AVAudioFile(forWriting: recordingURL, settings: format.settings)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        recognitionRequest = request
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let latency = (ProcessInfo.processInfo.systemUptime - self.lastBufferTime) * 1_000
            onTranscript(result.bestTranscription.formattedString, result.isFinal, latency)
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lastBufferTime = ProcessInfo.processInfo.systemUptime
            try? self.audioFile?.write(from: buffer)
            self.recognitionRequest?.append(buffer)
            if let reading = Self.meter(buffer) {
                onMeter(reading)
            }
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        return Self.routeSnapshot(session)
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionTask = nil
        recognitionRequest = nil
        audioFile = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    static func currentRouteSnapshot() -> AudioRouteSnapshot {
        routeSnapshot(AVAudioSession.sharedInstance())
    }

    private static func routeSnapshot(_ session: AVAudioSession) -> AudioRouteSnapshot {
        AudioRouteSnapshot(
            inputNames: session.currentRoute.inputs.map(\.portName),
            inputPortTypes: session.currentRoute.inputs.map { $0.portType.rawValue },
            outputNames: session.currentRoute.outputs.map(\.portName),
            outputPortTypes: session.currentRoute.outputs.map { $0.portType.rawValue },
            sampleRate: session.sampleRate,
            inputChannels: session.inputNumberOfChannels,
            outputChannels: session.outputNumberOfChannels,
            ioBufferDuration: session.ioBufferDuration
        )
    }

    private static func meter(_ buffer: AVAudioPCMBuffer) -> MeterReading? {
        guard let data = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }
        var sum: Float = 0
        var peak: Float = 0
        for index in 0..<count {
            let value = abs(data[index])
            sum += value * value
            peak = max(peak, value)
        }
        let rms = sqrt(sum / Float(count))
        let floorValue: Float = 0.000_001
        return MeterReading(
            rmsDBFS: Double(20 * log10(max(rms, floorValue))),
            peakDBFS: Double(20 * log10(max(peak, floorValue)))
        )
    }

    enum CaptureError: LocalizedError {
        case noAudioInput

        var errorDescription: String? {
            "利用可能な音声入力がありません。AirPodsの接続とマイク権限を確認してください。"
        }
    }
}
