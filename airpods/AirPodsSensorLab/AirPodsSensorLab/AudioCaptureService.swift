import AVFoundation
import Darwin
import Foundation
import Speech

final class AudioCaptureService {
    struct MeterReading: Sendable {
        let rmsDBFS: Double?
        let peakDBFS: Double?
        let callbackUptimeSeconds: Double
        let sessionElapsedSeconds: Double
        let hostTimeRaw: UInt64
        let hostTimeSeconds: Double?
        let hostTimeValid: Bool
        let sampleTime: Int64
        let sampleTimeValid: Bool
        let frameCount: UInt32
    }

    struct StartResult {
        let route: AudioRouteSnapshot
        let configuredSessionMode: String
        let highQualityFallbackUsed: Bool
    }

    struct StopResult {
        let recognitionEvents: [RecognitionEvent]
        let captureErrorDescription: String?
        let speechRecognitionErrorDescription: String?
        let speechRecognitionTimedOut: Bool
    }

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let stateLock = NSLock()
    private let audioProcessingQueue = DispatchQueue(
        label: "com.kimoto.AirPodsSensorLab.audio-processing",
        qos: .userInitiated
    )
    private let finalRecognitionWaiter = CompletionWaiter()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var sinkNode: AVAudioSinkNode?
    private var audioBufferPoolLock = os_unfair_lock_s()
    private var availableAudioBuffers: [PooledAudioBuffer] = []
    private var droppedAudioBufferCount: Int64 = 0
    private var droppedAudioFrameCount: Int64 = 0
    private var audioCopyFailureCount: Int64 = 0
    private var sessionOriginUptime = 0.0
    private var firstAudioCallbackUptime: Double?
    private var lastAudioCallbackUptime: Double?
    private var recognitionEvents: [RecognitionEvent] = []
    private var currentGeneration: UUID?
    private var captureErrorDescription: String?
    private var speechRecognitionErrorDescription: String?

    static func requestPermissions() async -> Bool {
        let microphone = await AVAudioApplication.requestRecordPermission()
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return microphone && speech
    }

    static func configureSession(for qualityMode: AudioQualityMode) throws {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        var mode: AVAudioSession.Mode = .measurement
        if qualityMode == .highQualityRecording {
            if #available(iOS 26.0, *) {
                options.insert(.bluetoothHighQualityRecording)
                mode = .default
            }
        }
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: mode, options: options)
    }

    @MainActor
    func start(
        recordingURL: URL,
        qualityMode: AudioQualityMode,
        sessionOriginUptime: Double,
        onMeter: @escaping @Sendable (MeterReading) -> Void,
        onTranscript: @escaping @Sendable (RecognitionEvent) -> Void
    ) async throws -> StartResult {
        let session = AVAudioSession.sharedInstance()
        try Self.configureSession(for: qualityMode)
        try session.setPreferredIOBufferDuration(0.02)
        try await Task.detached(priority: .userInitiated) {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        }.value

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noAudioInput
        }

        self.sessionOriginUptime = sessionOriginUptime
        let generation = UUID()
        stateLock.withLock {
            firstAudioCallbackUptime = nil
            lastAudioCallbackUptime = nil
            recognitionEvents.removeAll(keepingCapacity: true)
            currentGeneration = generation
            captureErrorDescription = nil
            speechRecognitionErrorDescription = nil
        }
        droppedAudioBufferCount = 0
        droppedAudioFrameCount = 0
        audioCopyFailureCount = 0
        finalRecognitionWaiter.reset()

        audioFile = try AVAudioFile(forWriting: recordingURL, settings: format.settings)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        recognitionRequest = request
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            guard self.stateLock.withLock({ self.currentGeneration == generation }) else { return }
            if let result {
                let callbackUptime = ProcessInfo.processInfo.systemUptime
                let callbackTimes = self.stateLock.withLock {
                    (self.firstAudioCallbackUptime, self.lastAudioCallbackUptime)
                }
                let segments = result.bestTranscription.segments
                let segmentEnd = segments.last.map { $0.timestamp + $0.duration }
                let estimatedDeliveryLatency = callbackTimes.0.flatMap { firstCallback in
                    segmentEnd.map { end in (callbackUptime - (firstCallback + end)) * 1_000 }
                }
                let event = RecognitionEvent(
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal,
                    callbackUptimeSeconds: callbackUptime,
                    sessionElapsedSeconds: callbackUptime - self.sessionOriginUptime,
                    millisecondsSinceFirstAudioCallback: callbackTimes.0.map {
                        (callbackUptime - $0) * 1_000
                    },
                    millisecondsSinceLastAudioCallback: callbackTimes.1.map {
                        (callbackUptime - $0) * 1_000
                    },
                    estimatedMillisecondsFromTranscriptionEndToCallback: estimatedDeliveryLatency,
                    transcriptionSegmentStartSeconds: segments.first?.timestamp,
                    transcriptionSegmentEndSeconds: segmentEnd
                )
                let accepted = self.stateLock.withLock { () -> Bool in
                    guard self.currentGeneration == generation else { return false }
                    self.recognitionEvents.append(event)
                    return true
                }
                guard accepted else { return }
                onTranscript(event)
                if result.isFinal { self.finalRecognitionWaiter.signal() }
            }
            if let error {
                let accepted = self.stateLock.withLock { () -> Bool in
                    guard self.currentGeneration == generation else { return false }
                    self.speechRecognitionErrorDescription = error.localizedDescription
                    return true
                }
                if accepted { self.finalRecognitionWaiter.signal() }
            }
        }
        if recognitionTask == nil { finalRecognitionWaiter.signal() }

        guard let activeAudioFile = audioFile else { throw CaptureError.noAudioInput }
        let activeRequest = request

        let maximumFrameCapacity = AVAudioFrameCount(max(8_192, Int(ceil(format.sampleRate * 0.2))))
        let bufferPool = (0..<32).compactMap { _ in
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrameCapacity).map(PooledAudioBuffer.init)
        }
        guard bufferPool.count == 32 else { throw CaptureError.audioBufferAllocationFailed }
        replaceAudioBuffers(with: bufferPool)

        let sink = AVAudioSinkNode { [weak self] timestamp, frameCount, inputData in
            guard let self else { return noErr }
            guard let pooledBuffer = self.takeAudioBuffer(frameCount: frameCount) else {
                self.recordDroppedAudio(frameCount: frameCount)
                return noErr
            }
            let buffer = pooledBuffer.buffer
            guard Self.copy(inputData, frameCount: frameCount, to: buffer) else {
                self.audioProcessingQueue.async { [weak self] in
                    self?.returnAudioBuffer(pooledBuffer)
                }
                self.recordDroppedAudio(frameCount: frameCount, copyFailed: true)
                return noErr
            }

            let callbackUptime = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            let audioTimeStamp = timestamp.pointee
            let hostTimeValid = audioTimeStamp.mFlags.contains(.hostTimeValid)
            let sampleTimeValid = audioTimeStamp.mFlags.contains(.sampleTimeValid)
            let hostTimeRaw = audioTimeStamp.mHostTime
            let hostTimeSeconds = hostTimeValid
                ? AVAudioTime.seconds(forHostTime: hostTimeRaw)
                : nil
            let sampleTime = sampleTimeValid ? Int64(audioTimeStamp.mSampleTime) : 0
            self.audioProcessingQueue.async { [weak self] in
                guard let self else { return }
                defer { self.returnAudioBuffer(pooledBuffer) }
                let isCurrentGeneration = self.stateLock.withLock { () -> Bool in
                    guard self.currentGeneration == generation else { return false }
                    if self.firstAudioCallbackUptime == nil {
                        self.firstAudioCallbackUptime = callbackUptime
                    }
                    self.lastAudioCallbackUptime = callbackUptime
                    return true
                }
                guard isCurrentGeneration else { return }
                do {
                    try activeAudioFile.write(from: buffer)
                } catch {
                    self.recordCaptureErrorIfNeeded(error.localizedDescription)
                }
                activeRequest.append(buffer)
                let levels = Self.meter(buffer)
                onMeter(MeterReading(
                    rmsDBFS: levels?.rmsDBFS,
                    peakDBFS: levels?.peakDBFS,
                    callbackUptimeSeconds: callbackUptime,
                    sessionElapsedSeconds: callbackUptime - sessionOriginUptime,
                    hostTimeRaw: hostTimeRaw,
                    hostTimeSeconds: hostTimeSeconds,
                    hostTimeValid: hostTimeValid,
                    sampleTime: sampleTime,
                    sampleTimeValid: sampleTimeValid,
                    frameCount: frameCount
                ))
            }
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        sinkNode = sink

        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeSinkNode()
            replaceAudioBuffers(with: [])
            throw error
        }
        let route = Self.routeSnapshot(session)
        return StartResult(
            route: route,
            configuredSessionMode: session.mode.rawValue,
            highQualityFallbackUsed: qualityMode == .highQualityRecording
                && route.highQualityRecordingEnabled != true
                && route.inputPortTypes.contains(AVAudioSession.Port.bluetoothHFP.rawValue)
        )
    }

    @MainActor
    func stopAndWaitForFinalRecognition() async -> StopResult {
        if engine.isRunning { engine.stop() }
        removeSinkNode()
        audioProcessingQueue.sync {}
        materializeAudioCaptureFailureIfNeeded()
        replaceAudioBuffers(with: [])
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        let recognitionCompleted = await finalRecognitionWaiter.wait(timeoutNanoseconds: 1_500_000_000)
        recognitionTask?.cancel()
        let result = stateLock.withLock { () -> StopResult in
            currentGeneration = nil
            return StopResult(
                recognitionEvents: recognitionEvents,
                captureErrorDescription: captureErrorDescription,
                speechRecognitionErrorDescription: speechRecognitionErrorDescription,
                speechRecognitionTimedOut: !recognitionCompleted
            )
        }
        recognitionTask = nil
        recognitionRequest = nil
        audioFile = nil
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        return result
    }

    @MainActor
    func cancel() {
        if engine.isRunning { engine.stop() }
        removeSinkNode()
        audioProcessingQueue.sync {}
        replaceAudioBuffers(with: [])
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioFile = nil
        stateLock.withLock { currentGeneration = nil }
        finalRecognitionWaiter.signal()
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    static func currentRouteSnapshot() -> AudioRouteSnapshot {
        routeSnapshot(AVAudioSession.sharedInstance())
    }

    @MainActor
    private func removeSinkNode() {
        guard let sinkNode else { return }
        engine.disconnectNodeInput(sinkNode)
        engine.detach(sinkNode)
        self.sinkNode = nil
    }

    private func takeAudioBuffer(frameCount: AVAudioFrameCount) -> PooledAudioBuffer? {
        guard os_unfair_lock_trylock(&audioBufferPoolLock) else { return nil }
        defer { os_unfair_lock_unlock(&audioBufferPoolLock) }
        guard let pooledBuffer = availableAudioBuffers.last,
              pooledBuffer.buffer.frameCapacity >= frameCount else {
            return nil
        }
        availableAudioBuffers.removeLast()
        pooledBuffer.buffer.frameLength = frameCount
        return pooledBuffer
    }

    private func returnAudioBuffer(_ pooledBuffer: PooledAudioBuffer) {
        os_unfair_lock_lock(&audioBufferPoolLock)
        availableAudioBuffers.append(pooledBuffer)
        os_unfair_lock_unlock(&audioBufferPoolLock)
    }

    private func replaceAudioBuffers(with buffers: [PooledAudioBuffer]) {
        os_unfair_lock_lock(&audioBufferPoolLock)
        availableAudioBuffers = buffers
        os_unfair_lock_unlock(&audioBufferPoolLock)
    }

    private func recordDroppedAudio(frameCount: AVAudioFrameCount, copyFailed: Bool = false) {
        _ = OSAtomicAdd64Barrier(1, &droppedAudioBufferCount)
        _ = OSAtomicAdd64Barrier(Int64(frameCount), &droppedAudioFrameCount)
        if copyFailed {
            _ = OSAtomicAdd64Barrier(1, &audioCopyFailureCount)
        }
    }

    private func materializeAudioCaptureFailureIfNeeded() {
        let droppedBuffers = OSAtomicAdd64Barrier(0, &droppedAudioBufferCount)
        guard droppedBuffers > 0 else { return }
        let droppedFrames = OSAtomicAdd64Barrier(0, &droppedAudioFrameCount)
        let copyFailures = OSAtomicAdd64Barrier(0, &audioCopyFailureCount)
        recordCaptureErrorIfNeeded(
            "音声入力バッファが\(droppedBuffers)回、合計\(droppedFrames)フレーム欠落しました"
                + "（コピー失敗: \(copyFailures)回）。このセッションは音声連続性の評価に使用できません。"
        )
    }

    private func recordCaptureErrorIfNeeded(_ description: String) {
        stateLock.withLock {
            if captureErrorDescription == nil {
                captureErrorDescription = description
            }
        }
    }

    private static func copy(
        _ source: UnsafePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount,
        to destination: AVAudioPCMBuffer
    ) -> Bool {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return false }
        destination.frameLength = frameCount
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData,
                  destinationBuffer.mDataByteSize >= sourceBuffer.mDataByteSize else {
                return false
            }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
        }
        return true
    }

    private static func routeSnapshot(_ session: AVAudioSession) -> AudioRouteSnapshot {
        var highQualitySupported: Bool?
        var highQualityEnabled: Bool?
        if #available(iOS 26.0, *) {
            let capabilities = session.currentRoute.inputs.compactMap {
                $0.bluetoothMicrophoneExtension?.highQualityRecording
            }
            if !capabilities.isEmpty {
                highQualitySupported = capabilities.contains { $0.isSupported }
                highQualityEnabled = capabilities.contains { $0.isEnabled }
            }
        }
        return AudioRouteSnapshot(
            inputNames: session.currentRoute.inputs.map(\.portName),
            inputPortTypes: session.currentRoute.inputs.map { $0.portType.rawValue },
            outputNames: session.currentRoute.outputs.map(\.portName),
            outputPortTypes: session.currentRoute.outputs.map { $0.portType.rawValue },
            sampleRate: session.sampleRate,
            inputChannels: session.inputNumberOfChannels,
            outputChannels: session.outputNumberOfChannels,
            ioBufferDuration: session.ioBufferDuration,
            highQualityRecordingSupported: highQualitySupported,
            highQualityRecordingEnabled: highQualityEnabled
        )
    }

    private static func meter(_ buffer: AVAudioPCMBuffer) -> (rmsDBFS: Double, peakDBFS: Double)? {
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
        return (
            rmsDBFS: Double(20 * log10(max(rms, floorValue))),
            peakDBFS: Double(20 * log10(max(peak, floorValue)))
        )
    }

    enum CaptureError: LocalizedError {
        case noAudioInput
        case audioBufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .noAudioInput:
                "利用可能な音声入力がありません。AirPodsの接続とマイク権限を確認してください。"
            case .audioBufferAllocationFailed:
                "音声処理用バッファを確保できませんでした。"
            }
        }
    }
}

private final class PooledAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class CompletionWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignaled = false
    private var continuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func reset() {
        lock.withLock { isSignaled = false }
    }

    func signal() {
        let pending: [CheckedContinuation<Bool, Never>] = lock.withLock {
            isSignaled = true
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        pending.forEach { $0.resume(returning: true) }
    }

    func wait(timeoutNanoseconds: UInt64) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if isSignaled { return true }
                continuations[id] = continuation
                return false
            }
            if shouldResume {
                continuation.resume(returning: true)
            } else {
                Task.detached { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self?.timeout(id)
                }
            }
        }
    }

    private func timeout(_ id: UUID) {
        let continuation = lock.withLock { continuations.removeValue(forKey: id) }
        continuation?.resume(returning: false)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
