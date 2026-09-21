import Foundation

struct SessionStore {
    let rootURL: URL

    init(fileManager: FileManager = .default) throws {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        rootURL = documents.appendingPathComponent("SensorSessions", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func makeSessionDirectory(id: UUID, startedAt: Date) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let safeDate = formatter.string(from: startedAt).replacingOccurrences(of: ":", with: "-")
        let directory = rootURL.appendingPathComponent("\(safeDate)_\(id.uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func save(session: LabSession, samples: [SensorSample], to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
        try session.transcript.write(
            to: directory.appendingPathComponent("transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        try csv(samples).write(
            to: directory.appendingPathComponent("sensor_samples.csv"),
            atomically: true,
            encoding: .utf8
        )
    }

    func listSessions() -> [StoredSession] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard url.hasDirectoryPath else { return nil }
            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            return StoredSession(id: UUID(), startedAt: values?.creationDate ?? .distantPast, directoryURL: url)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    private func csv(_ samples: [SensorSample]) -> String {
        let header = "elapsed_seconds,kind,rms_dbfs,peak_dbfs,pitch_deg,yaw_deg,roll_deg,accel_x,accel_y,accel_z"
        let rows = samples.map { sample in
            [
                format(sample.elapsedSeconds), sample.kind.rawValue,
                format(sample.rmsDBFS), format(sample.peakDBFS),
                format(sample.pitchDegrees), format(sample.yawDegrees), format(sample.rollDegrees),
                format(sample.userAccelerationX), format(sample.userAccelerationY), format(sample.userAccelerationZ)
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

