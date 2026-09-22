import Foundation

enum TestEnvironment: String, CaseIterable, Codable, Identifiable {
    case quietRoom = "静かな部屋"
    case office = "オフィス"
    case cafe = "カフェ"
    case outdoors = "屋外"
    case walking = "歩行中"

    var id: String { rawValue }
}

enum SpeakerTarget: String, CaseIterable, Codable, Identifiable {
    case wearer = "装着者"
    case otherPerson = "他者"
    case conversation = "会話"

    var id: String { rawValue }
}

enum AudioQualityMode: String, CaseIterable, Codable, Identifiable {
    case standardHFP
    case highQualityRecording

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standardHFP: "標準 HFP"
        case .highQualityRecording: "高音質録音（iOS 26+）"
        }
    }
}

enum ExperimentLabel: String, CaseIterable, Codable, Identifiable {
    case stationary = "静止"
    case lookLeft = "左向き"
    case lookRight = "右向き"
    case nod = "nod"
    case shake = "shake"
    case walking = "歩行"
    case speaking = "発話中"
    case other = "その他"

    var id: String { rawValue }
}

struct AudioRouteSnapshot: Codable {
    let inputNames: [String]
    let inputPortTypes: [String]
    let outputNames: [String]
    let outputPortTypes: [String]
    let sampleRate: Double
    let inputChannels: Int
    let outputChannels: Int
    let ioBufferDuration: Double
    let highQualityRecordingSupported: Bool?
    let highQualityRecordingEnabled: Bool?

    var usesBluetoothInput: Bool {
        inputPortTypes.contains { $0.localizedCaseInsensitiveContains("Bluetooth") }
    }
}

struct SensorSample: Codable {
    enum Kind: String, Codable { case audio, motion }

    let elapsedSeconds: Double
    let kind: Kind
    var rmsDBFS: Double? = nil
    var peakDBFS: Double? = nil
    var pitchDegrees: Double? = nil
    var yawDegrees: Double? = nil
    var rollDegrees: Double? = nil
    var userAccelerationX: Double? = nil
    var userAccelerationY: Double? = nil
    var userAccelerationZ: Double? = nil

    var sessionElapsedSeconds: Double? = nil
    var callbackUptimeSeconds: Double? = nil
    var mainActorArrivalUptimeSeconds: Double? = nil
    var mainActorArrivalElapsedSeconds: Double? = nil
    var label: ExperimentLabel? = nil
    var trialNumber: Int? = nil
    var motionSensorTimestampSeconds: Double? = nil
    var motionSensorElapsedSeconds: Double? = nil
    var rotationRateX: Double? = nil
    var rotationRateY: Double? = nil
    var rotationRateZ: Double? = nil
    var gravityX: Double? = nil
    var gravityY: Double? = nil
    var gravityZ: Double? = nil
    var audioHostTimeRaw: UInt64? = nil
    var audioHostTimeSeconds: Double? = nil
    var audioHostTimeElapsedSeconds: Double? = nil
    var audioHostTimeValid: Bool? = nil
    var audioSampleTime: Int64? = nil
    var audioSampleTimeValid: Bool? = nil
    var audioFrameCount: UInt32? = nil
}

struct RecognitionEvent: Codable {
    let text: String
    let isFinal: Bool
    let callbackUptimeSeconds: Double
    let sessionElapsedSeconds: Double
    let millisecondsSinceFirstAudioCallback: Double?
    let millisecondsSinceLastAudioCallback: Double?
    let estimatedMillisecondsFromTranscriptionEndToCallback: Double?
    let transcriptionSegmentStartSeconds: Double?
    let transcriptionSegmentEndSeconds: Double?
}

struct LabelEvent: Codable {
    enum Boundary: String, Codable { case start, end }

    let boundary: Boundary
    let label: ExperimentLabel
    let trialNumber: Int
    let callbackUptimeSeconds: Double
    let sessionElapsedSeconds: Double
}

struct RouteEvent: Codable {
    let callbackUptimeSeconds: Double
    let sessionElapsedSeconds: Double
    let reasonRawValue: UInt?
    let route: AudioRouteSnapshot
}

struct LabSession: Codable, Identifiable {
    let schemaVersion: Int
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let sessionMonotonicOriginUptimeSeconds: Double
    let environment: TestEnvironment
    let speakerTarget: SpeakerTarget
    let distanceMeters: Double
    let notes: String
    let requestedAudioQualityMode: AudioQualityMode
    let configuredAudioSessionMode: String
    let highQualityFallbackUsed: Bool
    let route: AudioRouteSnapshot
    let transcript: String
    let speechLatencyReference: String
    let partialSpeechLatencyMilliseconds: Double?
    let finalSpeechLatencyMilliseconds: Double?
    let captureErrorDescription: String?
    let speechRecognitionErrorDescription: String?
    let speechRecognitionTimedOut: Bool
    let motionAvailable: Bool
    let sampleCount: Int
    let recognitionEventCount: Int
    let labelEventCount: Int
    let routeEventCount: Int
}

struct StoredSession: Identifiable {
    let id: UUID
    let startedAt: Date
    let directoryURL: URL
}
