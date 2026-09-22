import AVFoundation
import Foundation

@MainActor
final class SensorLabViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isStopping = false
    @Published private(set) var isStarting = false
    @Published var duration: TimeInterval = 0
    @Published var rmsDBFS = -120.0
    @Published var peakDBFS = -120.0
    @Published var pitch = 0.0
    @Published var yaw = 0.0
    @Published var roll = 0.0
    @Published var transcript = ""
    @Published var speechLatencyMilliseconds: Double?
    @Published var route = AudioCaptureService.currentRouteSnapshot()
    @Published var environment: TestEnvironment = .quietRoom
    @Published var speakerTarget: SpeakerTarget = .wearer
    @Published var distanceMeters = 0.2
    @Published var notes = ""
    @Published var audioQualityMode: AudioQualityMode = .standardHFP
    @Published var selectedLabel: ExperimentLabel = .stationary
    @Published private(set) var activeTrialNumber: Int?
    @Published private(set) var activeTrialLabel: ExperimentLabel?
    @Published var sessions: [StoredSession] = []
    @Published var errorMessage: String?

    private let audio = AudioCaptureService()
    private let motion = HeadMotionService()
    private let callbackDrain = CallbackDrain()
    private var store: SessionStore?
    private var sessionID: UUID?
    private var startedAt: Date?
    private var sessionOriginUptime: Double?
    private var sessionDirectory: URL?
    private var configuredAudioSessionMode = ""
    private var highQualityFallbackUsed = false
    private var startRoute: AudioRouteSnapshot?
    private var requestedAudioQualityMode: AudioQualityMode = .standardHFP
    private var samples: [SensorSample] = []
    private var recognitionEvents: [RecognitionEvent] = []
    private var labelEvents: [LabelEvent] = []
    private var routeEvents: [RouteEvent] = []
    private var nextTrialNumber = 0
    private var timer: Timer?

    var motionAvailable: Bool { motion.isAvailable }
    var isAirPodsInput: Bool { route.usesBluetoothInput }

    init() {
        do {
            store = try SessionStore()
            sessions = store?.listSessions() ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            try AudioCaptureService.configureSession(for: .standardHFP)
            route = AudioCaptureService.currentRouteSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            Task { @MainActor in self?.handleRouteChange(reasonRawValue: reason) }
        }
    }

    func toggleRecording() {
        guard !isStopping else { return }
        if isRecording {
            Task { await stop() }
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isRecording, !isStarting, let store else { return }
        isStarting = true
        defer { isStarting = false }
        let selectedAudioQualityMode = audioQualityMode
        errorMessage = nil
        guard await AudioCaptureService.requestPermissions() else {
            errorMessage = "マイクまたは音声認識の権限がありません。設定アプリから許可してください。"
            return
        }

        do {
            let id = UUID()
            let originUptime = ProcessInfo.processInfo.systemUptime
            let now = Date()
            let directory = try store.makeSessionDirectory(id: id, startedAt: now)
            sessionID = id
            startedAt = now
            sessionOriginUptime = originUptime
            sessionDirectory = directory
            transcript = ""
            speechLatencyMilliseconds = nil
            samples.removeAll(keepingCapacity: true)
            recognitionEvents.removeAll(keepingCapacity: true)
            labelEvents.removeAll(keepingCapacity: true)
            routeEvents.removeAll(keepingCapacity: true)
            nextTrialNumber = 0
            activeTrialNumber = nil
            activeTrialLabel = nil
            duration = 0

            let result = try await audio.start(
                recordingURL: directory.appendingPathComponent("audio.caf"),
                qualityMode: selectedAudioQualityMode,
                sessionOriginUptime: originUptime,
                onMeter: { [weak self, callbackDrain] reading in
                    guard self != nil else { return }
                    callbackDrain.enter(sessionID: id)
                    Task { @MainActor [weak self, callbackDrain] in
                        self?.accept(reading, sessionID: id)
                        callbackDrain.leave(sessionID: id)
                    }
                },
                onTranscript: { [weak self, callbackDrain] event in
                    guard self != nil else { return }
                    callbackDrain.enter(sessionID: id)
                    Task { @MainActor [weak self, callbackDrain] in
                        self?.accept(event, sessionID: id)
                        callbackDrain.leave(sessionID: id)
                    }
                }
            )
            route = result.route
            startRoute = result.route
            requestedAudioQualityMode = selectedAudioQualityMode
            configuredAudioSessionMode = result.configuredSessionMode
            highQualityFallbackUsed = result.highQualityFallbackUsed
            motion.start(sessionOriginUptime: originUptime) { [weak self, callbackDrain] reading in
                guard self != nil else { return }
                callbackDrain.enter(sessionID: id)
                Task { @MainActor [weak self, callbackDrain] in
                    self?.accept(reading, sessionID: id)
                    callbackDrain.leave(sessionID: id)
                }
            }
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateDuration() }
            }
        } catch {
            audio.cancel()
            motion.stop()
            clearActiveSession()
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        guard isRecording,
              !isStopping,
              let store,
              let id = sessionID,
              let startedAt,
              let originUptime = sessionOriginUptime,
              let directory = sessionDirectory else { return }

        isStopping = true
        if activeTrialNumber != nil { endTrial() }
        let endedAt = Date()
        duration = endedAt.timeIntervalSince(startedAt)
        isRecording = false
        timer?.invalidate()
        timer = nil
        motion.stop()
        let stopResult = await audio.stopAndWaitForFinalRecognition()
        await callbackDrain.waitUntilEmpty(sessionID: id)
        recognitionEvents = stopResult.recognitionEvents
        if let latest = recognitionEvents.last {
            transcript = latest.text
            speechLatencyMilliseconds = latest.estimatedMillisecondsFromTranscriptionEndToCallback
        }

        let partialLatency = recognitionEvents.first(where: { !$0.isFinal })?
            .estimatedMillisecondsFromTranscriptionEndToCallback
        let finalLatency = recognitionEvents.last(where: { $0.isFinal })?
            .estimatedMillisecondsFromTranscriptionEndToCallback
        let result = LabSession(
            schemaVersion: 2,
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            sessionMonotonicOriginUptimeSeconds: originUptime,
            environment: environment,
            speakerTarget: speakerTarget,
            distanceMeters: distanceMeters,
            notes: notes,
            requestedAudioQualityMode: requestedAudioQualityMode,
            configuredAudioSessionMode: configuredAudioSessionMode,
            highQualityFallbackUsed: highQualityFallbackUsed,
            route: startRoute ?? route,
            transcript: transcript,
            speechLatencyReference: "recognition_callback_minus_estimated_transcription_segment_end",
            partialSpeechLatencyMilliseconds: partialLatency,
            finalSpeechLatencyMilliseconds: finalLatency,
            captureErrorDescription: stopResult.captureErrorDescription,
            speechRecognitionErrorDescription: stopResult.speechRecognitionErrorDescription,
            speechRecognitionTimedOut: stopResult.speechRecognitionTimedOut,
            motionAvailable: motionAvailable,
            sampleCount: samples.count,
            recognitionEventCount: recognitionEvents.count,
            labelEventCount: labelEvents.count,
            routeEventCount: routeEvents.count
        )
        do {
            try store.save(
                session: result,
                samples: samples,
                recognitionEvents: recognitionEvents,
                labelEvents: labelEvents,
                routeEvents: routeEvents,
                to: directory
            )
            sessions = store.listSessions()
        } catch {
            errorMessage = "計測結果の保存に失敗しました: \(error.localizedDescription)"
        }
        if let captureError = stopResult.captureErrorDescription {
            errorMessage = "音声ファイルへの書き込み中にエラーが発生しました: \(captureError)"
        }
        clearActiveSession()
        isStopping = false
    }

    func startTrial() {
        guard isRecording, activeTrialNumber == nil, let origin = sessionOriginUptime else { return }
        nextTrialNumber += 1
        let uptime = ProcessInfo.processInfo.systemUptime
        activeTrialNumber = nextTrialNumber
        activeTrialLabel = selectedLabel
        labelEvents.append(LabelEvent(
            boundary: .start,
            label: selectedLabel,
            trialNumber: nextTrialNumber,
            callbackUptimeSeconds: uptime,
            sessionElapsedSeconds: uptime - origin
        ))
    }

    func endTrial() {
        guard isRecording,
              let trialNumber = activeTrialNumber,
              let label = activeTrialLabel,
              let origin = sessionOriginUptime else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        labelEvents.append(LabelEvent(
            boundary: .end,
            label: label,
            trialNumber: trialNumber,
            callbackUptimeSeconds: uptime,
            sessionElapsedSeconds: uptime - origin
        ))
        activeTrialNumber = nil
        activeTrialLabel = nil
    }

    private func accept(_ reading: AudioCaptureService.MeterReading, sessionID callbackSessionID: UUID) {
        guard sessionID == callbackSessionID, let origin = sessionOriginUptime else { return }
        let arrivalUptime = ProcessInfo.processInfo.systemUptime
        let trial = trialContext(at: reading.sessionElapsedSeconds)
        if let value = reading.rmsDBFS { rmsDBFS = value }
        if let value = reading.peakDBFS { peakDBFS = value }
        samples.append(SensorSample(
            elapsedSeconds: reading.sessionElapsedSeconds,
            kind: .audio,
            rmsDBFS: reading.rmsDBFS,
            peakDBFS: reading.peakDBFS,
            sessionElapsedSeconds: reading.sessionElapsedSeconds,
            callbackUptimeSeconds: reading.callbackUptimeSeconds,
            mainActorArrivalUptimeSeconds: arrivalUptime,
            mainActorArrivalElapsedSeconds: arrivalUptime - origin,
            label: trial?.label,
            trialNumber: trial?.number,
            audioHostTimeRaw: reading.hostTimeRaw,
            audioHostTimeSeconds: reading.hostTimeSeconds,
            audioHostTimeElapsedSeconds: reading.hostTimeSeconds.map { $0 - origin },
            audioHostTimeValid: reading.hostTimeValid,
            audioSampleTime: reading.sampleTime,
            audioSampleTimeValid: reading.sampleTimeValid,
            audioFrameCount: reading.frameCount
        ))
    }

    private func accept(_ reading: HeadMotionService.Reading, sessionID callbackSessionID: UUID) {
        guard sessionID == callbackSessionID, let origin = sessionOriginUptime else { return }
        let arrivalUptime = ProcessInfo.processInfo.systemUptime
        let trial = trialContext(at: reading.sessionElapsedSeconds)
        pitch = reading.pitchDegrees
        yaw = reading.yawDegrees
        roll = reading.rollDegrees
        samples.append(SensorSample(
            elapsedSeconds: reading.sessionElapsedSeconds,
            kind: .motion,
            pitchDegrees: reading.pitchDegrees,
            yawDegrees: reading.yawDegrees,
            rollDegrees: reading.rollDegrees,
            userAccelerationX: reading.accelerationX,
            userAccelerationY: reading.accelerationY,
            userAccelerationZ: reading.accelerationZ,
            sessionElapsedSeconds: reading.sessionElapsedSeconds,
            callbackUptimeSeconds: reading.callbackUptimeSeconds,
            mainActorArrivalUptimeSeconds: arrivalUptime,
            mainActorArrivalElapsedSeconds: arrivalUptime - origin,
            label: trial?.label,
            trialNumber: trial?.number,
            motionSensorTimestampSeconds: reading.sensorTimestampSeconds,
            motionSensorElapsedSeconds: reading.sensorElapsedSeconds,
            rotationRateX: reading.rotationRateX,
            rotationRateY: reading.rotationRateY,
            rotationRateZ: reading.rotationRateZ,
            gravityX: reading.gravityX,
            gravityY: reading.gravityY,
            gravityZ: reading.gravityZ
        ))
    }

    private func accept(_ event: RecognitionEvent, sessionID callbackSessionID: UUID) {
        guard sessionID == callbackSessionID else { return }
        transcript = event.text
        speechLatencyMilliseconds = event.estimatedMillisecondsFromTranscriptionEndToCallback
    }

    private func handleRouteChange(reasonRawValue: UInt?) {
        let snapshot = AudioCaptureService.currentRouteSnapshot()
        route = snapshot
        guard isRecording, let origin = sessionOriginUptime else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        routeEvents.append(RouteEvent(
            callbackUptimeSeconds: uptime,
            sessionElapsedSeconds: uptime - origin,
            reasonRawValue: reasonRawValue,
            route: snapshot
        ))
    }

    private func trialContext(at elapsedSeconds: Double) -> (label: ExperimentLabel, number: Int)? {
        var context: (label: ExperimentLabel, number: Int)?
        for event in labelEvents where event.sessionElapsedSeconds <= elapsedSeconds {
            switch event.boundary {
            case .start:
                context = (event.label, event.trialNumber)
            case .end where context?.number == event.trialNumber:
                context = nil
            case .end:
                break
            }
        }
        return context
    }

    private func updateDuration() {
        guard let origin = sessionOriginUptime else { return }
        duration = ProcessInfo.processInfo.systemUptime - origin
    }

    private func clearActiveSession() {
        sessionID = nil
        startedAt = nil
        sessionOriginUptime = nil
        sessionDirectory = nil
        startRoute = nil
        activeTrialNumber = nil
        activeTrialLabel = nil
    }
}

private final class CallbackDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: Int] = [:]
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func enter(sessionID: UUID) {
        lock.lock()
        pending[sessionID, default: 0] += 1
        lock.unlock()
    }

    func leave(sessionID: UUID) {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            let remaining = max(0, (pending[sessionID] ?? 1) - 1)
            if remaining > 0 {
                pending[sessionID] = remaining
                return []
            }
            pending.removeValue(forKey: sessionID)
            return waiters.removeValue(forKey: sessionID) ?? []
        }
        continuations.forEach { $0.resume() }
    }

    func waitUntilEmpty(sessionID: UUID) async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if pending[sessionID, default: 0] == 0 { return true }
                waiters[sessionID, default: []].append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }
}
