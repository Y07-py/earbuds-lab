# AirPods Sensor Lab

AirPodsを独自イヤホン設計の比較基準として使うための、iPhone向け計測アプリです。

## 収集するデータ（schema v2）

- 実際に選択された音声入力・出力ルート
- サンプルレート、チャンネル数、I/Oバッファ長
- 音声（CAF）
- RMS／Peak音量（dBFS）
- 日本語リアルタイム文字起こし（partial／final別）とコールバック遅延
- AirPods Head MotionのPitch／Yaw／Roll、ユーザー加速度、角速度、重力
- Motion sensor timestamp、Audio host/sample time、各コールバック到着時刻
- 動作ラベルと試行番号（静止、左向き、右向き、nod、shake、歩行、発話中、その他）
- 録音中の音声ルート変更
- 環境、話者、距離、自由記述メモ

停止時に、アプリのDocuments/SensorSessions以下へ次のファイルを保存します。

```text
<session>/
  audio.caf
  metadata.json
  sensor_samples.csv
  recognition_events.csv
  label_events.csv
  route_events.csv
  transcript.txt
```

`metadata.json` の `schemaVersion` は `2` です。`sensor_samples.csv` の先頭10列はv1と同じで、既存の解析コードとの互換性を維持しています。追加ファイルの内容は次のとおりです。

- `recognition_events.csv`: partial/final、認識コールバック時刻、最初／最後の音声コールバックからの診断値、Speech frameworkが返す発話区間、発話区間終端から認識コールバックまでの推定遅延
- `label_events.csv`: 試行の開始／終了境界、ラベル、試行番号
- `route_events.csv`: 録音開始後に発生したルート変更。開始時点の正確なルートは `metadata.json` の `route`

### 時刻の読み方

セッション開始直前の `ProcessInfo.systemUptime` を `sessionMonotonicOriginUptimeSeconds` として固定し、AudioとMotionで共有します。壁時計ではないため、端末の時計変更の影響を受けません。

- `callback_uptime_seconds`: Audio Sink／Head Motion callback内で取得した単調時刻
- `session_elapsed_seconds`: `callback_uptime_seconds - sessionMonotonicOriginUptimeSeconds`。サンプルの正準経過時刻
- `elapsed_seconds`: v1互換列。v2では `session_elapsed_seconds` と同じ値
- `motion_sensor_timestamp_seconds`: `CMDeviceMotion.timestamp`。重複値は保存しません
- `motion_sensor_elapsed_seconds`: Motion sensor timestampを共通originへ対応付けた値
- `audio_host_time_raw` / `audio_host_time_seconds`: `AVAudioTime.hostTime` と秒換算値
- `audio_host_time_elapsed_seconds`: Audio host timeを共通originへ対応付けた値
- `audio_sample_time`: Audio stream内のsample position
- `main_actor_arrival_*`: UI／保存担当へ届いた時刻。配送遅延の診断用であり、サンプル時刻には使いません

更新周期の解析にはMotionなら `motion_sensor_timestamp_seconds`、Audioとの対応にはsource由来のelapsed列を優先し、callbackとMainActorの列は配送遅延の確認に使ってください。

### 音声モード

- `standardHFP`: `.measurement` と `allowBluetoothHFP`
- `highQualityRecording`: iOS 26以降で `.default` と `bluetoothHighQualityRecording` を要求し、`allowBluetoothHFP` をfallbackとして併用

High Quality RecordingはiOS 26以降かつ対応Bluetooth入力でのみ有効です。iOS 18〜25や非対応機器では安全に標準HFPへfallbackします。要求したモード、実際のAudio Session mode、開始ルート入力のHQ対応／有効状態、fallbackの有無は `metadata.json` に保存されます。

### Audioバッファ

Audio Sessionへ20 msのI/Oバッファを要求し、入力は`AVAudioSinkNode`から受け取ります。ただし、Bluetooth機器とiOSが要求値を採用する保証はありません。達成判定には希望値ではなく、`metadata.json` の `route.ioBufferDuration` と、`sensor_samples.csv` の `audio_frame_count / sampleRate`、callback間隔を使用します。

## Xcodeで開く

1. MacにXcode 26以降とXcodeGenを用意します。
2. このフォルダで `xcodegen generate` を実行します。
3. `AirPodsSensorLab.xcodeproj` を開きます。
4. Signing & Capabilitiesで自分のTeamを選び、実機iPhoneへインストールします。

```bash
brew install xcodegen
cd AirPodsSensorLab
xcodegen generate
open AirPodsSensorLab.xcodeproj
```

シミュレータではAirPodsの実入力とHead Motionを検証できません。必ず実機を使ってください。

## v2の実験手順

固定の例文と頭部動作を使う計測では、[MEASUREMENT_SCRIPT_JA.md](MEASUREMENT_SCRIPT_JA.md) の台本に従ってください。試行順、正解文、動作タイミングを固定することで、セッション間のASR精度とMotion特徴を比較できます。

1. AirPodsを接続し、「Bluetooth入力: 接続済み」を確認します。
2. 音声モードを選び、計測を開始します。録音開始後のルート表示も再確認します。
3. 「試行ラベル」で動作を選び、「選択した試行を開始」を押します。
4. 動作を1回実施して「この試行を終了」を押します。同じラベルを目安として10回繰り返します。
5. 計測を停止します。final認識結果を最大約1.5秒待ってからファイルが保存されます。

まず静かな部屋で `静止`、`左向き`、`右向き`、`nod`、`shake`、`発話中` を取得し、その後 `歩行` と雑音条件へ進めます。音質比較では同じ文章・距離・再生音量を保ち、`standardHFP` と `highQualityRecording` を別セッションで記録します。

音声条件の基本セットは次のとおりです。

1. 装着者の声、静かな部屋
2. 他者の声、距離1 m、静かな部屋
3. 他者の声、距離2 m、静かな部屋
4. 他者の声、距離3 m、静かな部屋
5. 1〜4をオフィスまたはカフェで再実施

Bluetooth入力が「接続済み」であることを毎回確認してください。iOSがiPhone本体マイクへ切り替わったセッションは `route_events.csv` と開始ルートを確認し、比較から除外してください。

## 現時点の制約

- ANC、ビームフォーミング、Adaptive Audio内部の生データはAppleの公開APIから取得できません。
- `partialSpeechLatencyMilliseconds` と `finalSpeechLatencyMilliseconds` は、最初のaudio callbackとSpeech frameworkの発話区間終端を対応付けた推定時刻から、認識callbackまでの差です。前者は最初のpartial、後者はfinalを対象とします。音がマイクへ到達してからAI応答開始までの完全なE2E遅延ではありません。
- Speech frameworkがfinalを返さない場合、約1.5秒で保存を継続し、finalの遅延は `null`、`speechRecognitionTimedOut` は `true` になります。認識エラーは `speechRecognitionErrorDescription` に保存します。
- Head MotionはCore Motion処理済みデータであり、AirPods内部IMUのrawレジスタ値ではありません。
- バックグラウンド常時録音には対応していません。
- 収録音声や会話を共有する場合は、参加者の同意を得てください。
