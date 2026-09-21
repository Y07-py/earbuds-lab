# AirPods Sensor Lab

AirPodsを独自イヤホン設計の比較基準として使うための、iPhone向け計測アプリです。

## 収集するデータ

- 実際に選択された音声入力・出力ルート
- サンプルレート、チャンネル数、I/Oバッファ長
- 音声（CAF）
- RMS／Peak音量（dBFS）
- 日本語リアルタイム文字起こしと概算応答遅延
- AirPods Head MotionのPitch／Yaw／Rollとユーザー加速度
- 環境、話者、距離、自由記述メモ

停止時に、アプリのDocuments/SensorSessions以下へ次のファイルを保存します。

```text
<session>/
  audio.caf
  metadata.json
  sensor_samples.csv
  transcript.txt
```

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

## 最初の実験

各条件で同じ文章を3回読み、セッションを分けて保存します。

1. 装着者の声、静かな部屋
2. 他者の声、距離1 m、静かな部屋
3. 他者の声、距離2 m、静かな部屋
4. 他者の声、距離3 m、静かな部屋
5. 1〜4をオフィスまたはカフェで再実施

Bluetooth入力が「接続済み」であることを毎回確認してください。iOSがiPhone本体マイクへ切り替わると比較結果が無効になります。

## 現時点の制約

- ANC、ビームフォーミング、Adaptive Audio内部の生データはAppleの公開APIから取得できません。
- 音声認識の遅延値は最後の音声バッファ受信から認識結果コールバックまでの概算です。
- バックグラウンド常時録音には対応していません。
- 収録音声や会話を共有する場合は、参加者の同意を得てください。

