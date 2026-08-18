# クライアントからの利用

[← README に戻る](../README.md)

---

## Windows からの音声ダウンロード

Mac を TTS サーバーとして LAN 上に置き、Windows から音声を取得する例。

```powershell
# Mac の LAN IP に合わせて変更
$mac = "http://192.168.1.50:8000"

# mode=file で音声ファイルを直接ダウンロード (推奨)
Invoke-WebRequest -Uri "$mac/api/v1/synthesize?mode=file" `
  -Method Post `
  -ContentType "application/json" `
  -Body '{"text": "こんにちは", "voice": "Kyoko", "format": "wav"}' `
  -OutFile "audio.wav"

# または: JSON でメタデータを取得してから URL でダウンロード
$resp = Invoke-RestMethod -Uri "$mac/api/v1/synthesize" `
  -Method Post -ContentType "application/json" `
  -Body '{"text": "こんにちは", "voice": "Kyoko", "format": "wav"}'
Invoke-WebRequest -Uri "$mac$($resp.url)" -OutFile "audio.wav"
```

> **フォーマット推奨**: Windows で確実に再生するには `"format": "wav"` を指定する。
> `m4a` はコーデックが無いと再生できない場合がある。
