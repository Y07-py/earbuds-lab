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

    func save(
        session: LabSession,
        samples: [SensorSample],
        recognitionEvents: [RecognitionEvent],
        labelEvents: [LabelEvent],
        routeEvents: [RouteEvent],
        to directory: URL
    ) throws {
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
        try recognitionCSV(recognitionEvents).write(
            to: directory.appendingPathComponent("recognition_events.csv"),
            atomically: true,
            encoding: .utf8
        )
        try labelCSV(labelEvents).write(
            to: directory.appendingPathComponent("label_events.csv"),
            atomically: true,
            encoding: .utf8
        )
        try routeCSV(routeEvents).write(
            to: directory.appendingPathComponent("route_events.csv"),
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
        let header = [
            "elapsed_seconds", "kind", "rms_dbfs", "peak_dbfs", "pitch_deg", "yaw_deg",
            "roll_deg", "accel_x", "accel_y", "accel_z",
            "session_elapsed_seconds", "callback_uptime_seconds",
            "main_actor_arrival_uptime_seconds", "main_actor_arrival_elapsed_seconds",
            "label", "trial_number", "motion_sensor_timestamp_seconds",
            "motion_sensor_elapsed_seconds", "rotation_rate_x", "rotation_rate_y",
            "rotation_rate_z", "gravity_x", "gravity_y", "gravity_z",
            "audio_host_time_raw", "audio_host_time_seconds", "audio_host_time_elapsed_seconds",
            "audio_host_time_valid",
            "audio_sample_time", "audio_sample_time_valid", "audio_frame_count"
        ].joined(separator: ",")
        let rows = samples.map { sample in
            [
                format(sample.elapsedSeconds), sample.kind.rawValue,
                format(sample.rmsDBFS), format(sample.peakDBFS),
                format(sample.pitchDegrees), format(sample.yawDegrees), format(sample.rollDegrees),
                format(sample.userAccelerationX), format(sample.userAccelerationY), format(sample.userAccelerationZ),
                format(sample.sessionElapsedSeconds), format(sample.callbackUptimeSeconds),
                format(sample.mainActorArrivalUptimeSeconds), format(sample.mainActorArrivalElapsedSeconds),
                sample.label.map { csvEscape($0.rawValue) } ?? "", format(sample.trialNumber),
                format(sample.motionSensorTimestampSeconds), format(sample.motionSensorElapsedSeconds),
                format(sample.rotationRateX), format(sample.rotationRateY), format(sample.rotationRateZ),
                format(sample.gravityX), format(sample.gravityY), format(sample.gravityZ),
                format(sample.audioHostTimeRaw), format(sample.audioHostTimeSeconds),
                format(sample.audioHostTimeElapsedSeconds), format(sample.audioHostTimeValid),
                format(sample.audioSampleTime),
                format(sample.audioSampleTimeValid), format(sample.audioFrameCount)
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private func recognitionCSV(_ events: [RecognitionEvent]) -> String {
        let header = "callback_uptime_seconds,session_elapsed_seconds,is_final,milliseconds_since_first_audio_callback,milliseconds_since_last_audio_callback,estimated_milliseconds_from_transcription_end_to_callback,transcription_segment_start_seconds,transcription_segment_end_seconds,text"
        let rows = events.map { event in
            [
                format(event.callbackUptimeSeconds), format(event.sessionElapsedSeconds),
                format(event.isFinal), format(event.millisecondsSinceFirstAudioCallback),
                format(event.millisecondsSinceLastAudioCallback),
                format(event.estimatedMillisecondsFromTranscriptionEndToCallback),
                format(event.transcriptionSegmentStartSeconds),
                format(event.transcriptionSegmentEndSeconds), csvEscape(event.text)
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private func labelCSV(_ events: [LabelEvent]) -> String {
        let header = "callback_uptime_seconds,session_elapsed_seconds,boundary,label,trial_number"
        let rows = events.map { event in
            [
                format(event.callbackUptimeSeconds), format(event.sessionElapsedSeconds),
                event.boundary.rawValue, csvEscape(event.label.rawValue), format(event.trialNumber)
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private func routeCSV(_ events: [RouteEvent]) -> String {
        let header = "callback_uptime_seconds,session_elapsed_seconds,reason_raw_value,input_names,input_port_types,output_names,output_port_types,sample_rate,input_channels,output_channels,io_buffer_duration,high_quality_recording_supported,high_quality_recording_enabled"
        let rows = events.map { event in
            let route = event.route
            return [
                format(event.callbackUptimeSeconds), format(event.sessionElapsedSeconds),
                format(event.reasonRawValue), csvEscape(route.inputNames.joined(separator: " | ")),
                csvEscape(route.inputPortTypes.joined(separator: " | ")),
                csvEscape(route.outputNames.joined(separator: " | ")),
                csvEscape(route.outputPortTypes.joined(separator: " | ")),
                format(route.sampleRate), format(route.inputChannels), format(route.outputChannels),
                format(route.ioBufferDuration), format(route.highQualityRecordingSupported),
                format(route.highQualityRecordingEnabled)
            ].joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func format(_ value: Int?) -> String { value.map(String.init) ?? "" }
    private func format(_ value: UInt?) -> String { value.map(String.init) ?? "" }
    private func format(_ value: UInt32?) -> String { value.map(String.init) ?? "" }
    private func format(_ value: UInt64?) -> String { value.map(String.init) ?? "" }
    private func format(_ value: Int64?) -> String { value.map(String.init) ?? "" }
    private func format(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "" }

    private func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
