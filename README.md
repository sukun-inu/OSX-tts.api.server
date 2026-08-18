# OSX TTS API

macOS の `say` コマンドを利用したテキスト読み上げ (TTS) API サーバー。
HTTP でテキストを受け取って音声ファイルを生成し、FastAPI が直接配信する。

将来的に Discord ボットのコメント読み上げシステムへ統合することを想定しているが、
本リポジトリの対象は **API サーバー単体**（ボット統合は未実装）。

詳細な設計・仕様は **[docs/SPEC.md](docs/SPEC.md)** を参照。

## 必要環境

| 要件 | 用途 |
|------|------|
| macOS | `say` コマンド（音声生成）。**必須** |
| Python 3.11 以上 | API サーバー実行 |
| ffmpeg | `mp3` 形式を使う場合のみ |

> Windows 上ではコード編集はできるが `say` が無いため音声生成は動作しない。
> サーバー本体は macOS で実行すること。

---

## セットアップ & 起動

### 本番 (macOS — 常駐デーモン)

```bash
# GitHub から一発インストール
curl -fsSL https://raw.githubusercontent.com/sukun-inu/OSX-tts.api.server/main/scripts/install.sh | bash

# オプション付き (ポートや公開 URL を変える例)
curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash -s -- \
  --port 8000 \
  --public-url http://192.168.1.50:8000
```

インストール後の管理コマンド:

```bash
# 状態確認
sudo launchctl print system/local.tts-api

# 再起動
sudo launchctl kickstart -k system/local.tts-api

# ログ確認
tail -f /usr/local/var/log/tts-api/stderr.log

# アップデート
bash /usr/local/opt/tts-api/scripts/update.sh

# アンインストール (音声ファイルを残す場合)
bash /usr/local/opt/tts-api/scripts/uninstall.sh --keep-audio
```

### 開発 (ローカル起動)

```bash
# 設定ファイルを用意（必要に応じて編集）
cp .env.example .env

# 起動（仮想環境作成・依存インストール・起動を自動実行）
./scripts/start.sh
```

起動後、API ドキュメント (Swagger UI) を http://127.0.0.1:8000/docs で確認できる。

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

## ドキュメント

| | |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 全体構成、設定値の優先順位、音声ファイルのライフサイクル |
| [docs/STRUCTURE.md](docs/STRUCTURE.md) | リポジトリと本番インストール後のディレクトリ配置 |
| [docs/CLIENTS.md](docs/CLIENTS.md) | Windows・ブラウザ等からの音声ダウンロード |
