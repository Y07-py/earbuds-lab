import SwiftUI

struct ContentView: View {
    @StateObject private var model = SensorLabViewModel()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                experimentSection
                liveSection
                transcriptSection
                controlSection
                sessionsSection
            }
            .navigationTitle("AirPods Sensor Lab")
            .alert("エラー", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var statusSection: some View {
        Section("接続") {
            LabeledContent("音声入力", value: model.route.inputNames.joined(separator: ", ").ifEmpty("未検出"))
            LabeledContent("Bluetooth入力") {
                Label(model.isAirPodsInput ? "接続済み" : "未接続", systemImage: model.isAirPodsInput ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.isAirPodsInput ? .green : .orange)
            }
            LabeledContent("形式", value: "\(Int(model.route.sampleRate)) Hz / \(model.route.inputChannels) ch")
            LabeledContent("Head Motion", value: model.motionAvailable ? "利用可能" : "利用不可")
        }
    }

    private var experimentSection: some View {
        Section("実験条件") {
            Picker("環境", selection: $model.environment) {
                ForEach(TestEnvironment.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("話者", selection: $model.speakerTarget) {
                ForEach(SpeakerTarget.allCases) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Text("距離")
                Slider(value: $model.distanceMeters, in: 0.1...3.0, step: 0.1)
                Text(String(format: "%.1f m", model.distanceMeters)).monospacedDigit()
            }
            TextField("メモ（騒音、端末位置など）", text: $model.notes, axis: .vertical)
                .lineLimit(2...4)
        }
        .disabled(model.isRecording)
    }

    private var liveSection: some View {
        Section("ライブ計測") {
            LabeledContent("経過時間", value: model.duration.formatted(.number.precision(.fractionLength(1))) + " 秒")
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("入力レベル"); Spacer(); Text(String(format: "%.1f dBFS", model.rmsDBFS)).monospacedDigit() }
                ProgressView(value: max(0, min(1, (model.rmsDBFS + 60) / 60)))
            }
            LabeledContent("Pitch", value: String(format: "%.1f°", model.pitch))
            LabeledContent("Yaw", value: String(format: "%.1f°", model.yaw))
            LabeledContent("Roll", value: String(format: "%.1f°", model.roll))
            LabeledContent("音声→文字 遅延", value: model.speechLatencyMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—")
        }
    }

    private var transcriptSection: some View {
        Section("文字起こし") {
            Text(model.transcript.ifEmpty("録音を開始すると、ここに認識結果が表示されます。"))
                .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }

    private var controlSection: some View {
        Section {
            Button(action: model.toggleRecording) {
                Label(model.isRecording ? "計測を停止して保存" : "計測を開始", systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
                    .font(.headline)
                    .foregroundStyle(model.isRecording ? .red : .blue)
            }
        }
    }

    private var sessionsSection: some View {
        Section("保存済みセッション") {
            if model.sessions.isEmpty {
                Text("まだ計測結果はありません").foregroundStyle(.secondary)
            }
            ForEach(model.sessions) { session in
                ShareLink(item: session.directoryURL) {
                    HStack {
                        Image(systemName: "folder")
                        VStack(alignment: .leading) {
                            Text(session.directoryURL.lastPathComponent).lineLimit(1)
                            Text("タップして共有").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

#Preview { ContentView() }

