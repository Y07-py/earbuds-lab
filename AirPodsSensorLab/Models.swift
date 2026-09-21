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

struct AudioRouteSnapshot: Codable {
    let inputNames: [String]
    let inputPortTypes: [String]
    let outputNames: [String]
    let outputPortTypes: [String]
    let sampleRate: Double
    let inputChannels: Int
    let outputChannels: Int
    let ioBufferDuration: Double

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
}

struct LabSession: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let environment: TestEnvironment
    let speakerTarget: SpeakerTarget
    let distanceMeters: Double
    let notes: String
    let route: AudioRouteSnapshot
    let transcript: String
    let finalSpeechLatencyMilliseconds: Double?
    let motionAvailable: Bool
    let sampleCount: Int
}

struct StoredSession: Identifiable {
    let id: UUID
    let startedAt: Date
    let directoryURL: URL
}
