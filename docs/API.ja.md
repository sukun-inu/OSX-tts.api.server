# API リファレンス

[← README.ja.md に戻る](../README.ja.md)

---

## API クイックリファレンス

| メソッド | パス | 説明 |
|----------|------|------|
| POST | `/api/v1/synthesize` | テキストを音声に変換 |
| GET  | `/api/v1/voices` | 利用可能な音声の一覧 |
| GET  | `/api/v1/health` | ヘルスチェック |
| GET  | `/audio/{id}.{ext}` | 音声ファイル取得（FastAPI の StaticFiles が配信） |

### 例: 音声を生成する

```bash
curl -X POST http://127.0.0.1:8000/api/v1/synthesize \
  -H "Content-Type: application/json" \
  -d '{"text": "こんにちは", "voice": "Kyoko", "format": "wav"}'
```

レスポンス:

```json
{
  "id": "a1b2c3d4e5f6...",
  "url": "/audio/a1b2c3d4e5f6....wav",
  "format": "wav",
  "voice": "Kyoko",
  "rate": null,
  "size_bytes": 48000,
  "cached": false,
  "created_at": "2026-05-16T12:00:00+00:00"
}
```

音声ファイル本体を直接受け取る場合は `?mode=file` を付ける:

```bash
curl -X POST "http://127.0.0.1:8000/api/v1/synthesize?mode=file" \
  -H "Content-Type: application/json" \
  -d '{"text": "こんにちは"}' --output hello.wav
```

日本語音声だけを一覧する:

```bash
curl "http://127.0.0.1:8000/api/v1/voices?locale=ja"
```

---
