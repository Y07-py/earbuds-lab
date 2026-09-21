import AVFoundation
import Foundation

@MainActor
final class SensorLabViewModel: ObservableObject {
    @Published var isRecording = false
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
    @Published var sessions: [StoredSession] = []
    @Published var errorMessage: String?

    private let audio = AudioCaptureService()
    private let motion = HeadMotionService()
    private var store: SessionStore?
    private var sessionID: UUID?
    private var startedAt: Date?
    private var sessionDirectory: URL?
    private var samples: [SensorSample] = []
    private var timer: Timer?
    // start() は途中で await するため、完了前の二重開始（installTap の重複）を防ぐ。
    private var isStarting = false

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
            try AudioCaptureService.configureSession()
            route = AudioCaptureService.currentRouteSnapshot()
        } catch {
            errorMessage = error.localizedDescription
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.route = AudioCaptureService.currentRouteSnapshot() }
        }
    }

    func toggleRecording() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isRecording, !isStarting, let store else { return }
        isStarting = true
        defer { isStarting = false }
        errorMessage = nil
        guard await AudioCaptureService.requestPermissions() else {
            errorMessage = "マイクまたは音声認識の権限がありません。設定アプリから許可してください。"
            return
        }

        do {
            let id = UUID()
            let now = Date()
            let directory = try store.makeSessionDirectory(id: id, startedAt: now)
            sessionID = id
            startedAt = now
            sessionDirectory = directory
            transcript = ""
            speechLatencyMilliseconds = nil
            samples.removeAll(keepingCapacity: true)

            route = try await audio.start(
                recordingURL: directory.appendingPathComponent("audio.caf"),
                onMeter: { [weak self] reading in
                    Task { @MainActor in self?.accept(reading) }
                },
                onTranscript: { [weak self] text, _, latency in
                    Task { @MainActor in
                        self?.transcript = text
                        self?.speechLatencyMilliseconds = latency
                    }
                }
            )
            motion.start { [weak self] reading in
                Task { @MainActor in self?.accept(reading) }
            }
            isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateDuration() }
            }
        } catch {
            audio.stop()
            motion.stop()
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        guard isRecording,
              let store,
              let id = sessionID,
              let startedAt,
              let directory = sessionDirectory else { return }

        audio.stop()
        motion.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        let endedAt = Date()
        duration = endedAt.timeIntervalSince(startedAt)

        let result = LabSession(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            environment: environment,
            speakerTarget: speakerTarget,
            distanceMeters: distanceMeters,
            notes: notes,
            route: route,
            transcript: transcript,
            finalSpeechLatencyMilliseconds: speechLatencyMilliseconds,
            motionAvailable: motionAvailable,
            sampleCount: samples.count
        )
        do {
            try store.save(session: result, samples: samples, to: directory)
            sessions = store.listSessions()
        } catch {
            errorMessage = "計測結果の保存に失敗しました: \(error.localizedDescription)"
        }
    }

    private func accept(_ reading: AudioCaptureService.MeterReading) {
        guard isRecording || startedAt != nil else { return }
        rmsDBFS = reading.rmsDBFS
        peakDBFS = reading.peakDBFS
        samples.append(SensorSample(
            elapsedSeconds: elapsed(), kind: .audio,
            rmsDBFS: reading.rmsDBFS, peakDBFS: reading.peakDBFS
        ))
    }

    private func accept(_ reading: HeadMotionService.Reading) {
        guard isRecording else { return }
        pitch = reading.pitchDegrees
        yaw = reading.yawDegrees
        roll = reading.rollDegrees
        samples.append(SensorSample(
            elapsedSeconds: elapsed(), kind: .motion,
            pitchDegrees: reading.pitchDegrees, yawDegrees: reading.yawDegrees,
            rollDegrees: reading.rollDegrees,
            userAccelerationX: reading.accelerationX,
            userAccelerationY: reading.accelerationY,
            userAccelerationZ: reading.accelerationZ
        ))
    }

    private func updateDuration() { duration = elapsed() }
    private func elapsed() -> Double { Date().timeIntervalSince(startedAt ?? Date()) }
}

