# OSX TTS API

macOS の `say` コマンドを利用したテキスト読み上げ (TTS) API サーバー。
HTTP でテキストを受け取って音声ファイルを生成し、nginx 経由で配信する。

将来的に Discord ボットのコメント読み上げシステムへ統合することを想定しているが、
本リポジトリの対象は **API サーバー単体**（ボット統合は未実装）。

詳細な設計・仕様は **[docs/SPEC.md](docs/SPEC.md)** を参照。

## 必要環境

| 要件 | 用途 |
|------|------|
| macOS | `say` コマンド（音声生成）。**必須** |
| Python 3.11 以上 | API サーバー実行 |
| nginx | 本番配信（リバースプロキシ + 静的配信） |
| ffmpeg | `mp3` 形式を使う場合のみ |

> Windows 上ではコード編集はできるが `say` が無いため音声生成は動作しない。
> サーバー本体は macOS で実行すること。

## ディレクトリ構成

### リポジトリ

```
OSX-tts.api.server/
├── app/                  FastAPI アプリケーション
│   ├── __init__.py
│   ├── config.py         設定 (環境変数)
│   ├── schemas.py        リクエスト/レスポンススキーマ
│   ├── tts.py            say / ffmpeg ラッパー
│   ├── storage.py        音声ファイル管理・キャッシュ
│   └── main.py           エンドポイント定義
├── docs/
│   └── SPEC.md           仕様書
├── nginx/
│   └── tts-api.conf      nginx サイト設定テンプレート
├── scripts/
│   ├── install.sh        本番インストーラー (macOS)
│   ├── uninstall.sh      アンインストーラー (macOS)
│   └── start.sh          開発用 起動スクリプト
├── requirements.txt
├── .env.example
└── README.md
```

### 本番インストール後のディレクトリ配置

```
/usr/local/opt/tts-api/              ← アプリ本体 (git clone 先)
├── app/
├── scripts/
├── requirements.txt
├── .env                             ← 実行時設定 (install.sh が自動生成)
└── .venv/                           ← Python 仮想環境

/usr/local/var/audio/tts-api/        ← 生成音声ファイル (nginx alias と共有)
/usr/local/var/log/tts-api/          ← TTS API ログ (stdout/stderr)
/usr/local/var/log/nginx/            ← nginx ログ
/usr/local/var/run/nginx/            ← nginx 一時ファイル

/Library/LaunchDaemons/
├── local.nginx.plist                ← nginx 常駐デーモン (system)
└── local.tts-api.plist              ← TTS API 常駐デーモン (system)

# nginx サイト設定 (アーキテクチャにより異なる)
/opt/homebrew/etc/nginx/servers/tts-api.conf   ← Apple Silicon
/usr/local/etc/nginx/servers/tts-api.conf      ← Intel Mac
```

## 設定値の優先順位

高い順に後の設定が前の設定を上書きします。

| 優先度 | 方法 | 場所 / 例 |
|--------|------|-----------|
| 1 (最高) | **CLI オプション** (install 時のみ) | `--port 9000 --audio-dir /data/audio` |
| 2 | **環境変数** | `TTS_PORT=9000 bash install.sh` |
| 3 | **LaunchDaemon の EnvironmentVariables** | `/Library/LaunchDaemons/local.tts-api.plist` |
| 4 | **.env ファイル** | `/usr/local/opt/tts-api/.env` |
| 5 (最低) | **app/config.py のデフォルト値** | コード内の初期値 |

> **ポイント**: `.env` を直接編集して再起動するのが通常の設定変更手順。  
> plist の `EnvironmentVariables` は `.env` より優先されるため、  
> plist 側に設定が残っていると `.env` の変更が反映されないことに注意。

## セットアップ & 起動

### 本番 (macOS — 常駐デーモン)

```bash
# GitHub から一発インストール
curl -fsSL https://raw.githubusercontent.com/sukun-inu/OSX-tts.api.server/main/scripts/install.sh | bash

# オプション付き (ポート・音声ディレクトリを変更する例)
curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash -s -- \
  --port 8000 \
  --audio-dir /usr/local/var/audio/tts-api \
  --public-url http://192.168.1.50
```

インストール後の管理コマンド:

```bash
# 状態確認
sudo launchctl print system/local.tts-api
sudo launchctl print system/local.nginx

# 再起動
sudo launchctl kickstart -k system/local.tts-api
sudo launchctl kickstart -k system/local.nginx

# ログ確認
tail -f /usr/local/var/log/tts-api/stderr.log

# アンインストール (音声ファイルを残す場合)
bash /usr/local/opt/tts-api/scripts/uninstall.sh --keep-audio
```

### 開発 (ローカル起動)

```bash
# 1. 設定ファイルを用意（必要に応じて編集）
cp .env.example .env

# 2. 起動（仮想環境作成・依存インストール・起動を自動実行）
./scripts/start.sh
```

手動で起動する場合:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m app.main
```

起動後、API ドキュメント (Swagger UI) を http://127.0.0.1:8000/docs で確認できる。

## nginx の設定

`nginx/tts-api.conf` は本番インストール時に `install.sh` が自動で配置・設定する。  
手動でセットアップする場合は `CHANGEME` 箇所を環境に合わせて修正すること。

```bash
# Homebrew nginx (Apple Silicon) の例
cp nginx/tts-api.conf /opt/homebrew/etc/nginx/servers/tts-api.conf
nginx -t && nginx -s reload
```

## 音声ファイルのライフサイクル

生成した音声ファイルは以下の2ルートで自動削除される。ディスクを圧迫しない設計。

| ルート | タイミング | 詳細 |
|--------|-----------|------|
| **配信後削除** | ファイル送信完了の約5秒後 | `?mode=file` で FastAPI が直接返した場合。BackgroundTask で `unlink` |
| **TTL 削除** | 最終アクティビティから60秒後 | nginx 経由の配信は `atime` 更新で「最終アクセス」を追跡。15秒ごとのバックグラウンドが `max(mtime, atime) + 60s` を超えたファイルを削除 |

```
POST /synthesize?mode=file  →  FastAPI が送信  →  5秒後に削除
POST /synthesize?mode=json  →  nginx が /audio/ を配信  →  最終アクセスから60秒後に削除
```

各タイミングは `.env` で調整できる:

```env
TTS_AUDIO_TTL_SECONDS=60          # 最終アクセスから何秒で消すか
TTS_CLEANUP_INTERVAL_SECONDS=15   # バックグラウンドの掃除間隔
TTS_POST_SERVE_DELETE_DELAY=5     # mode=file 配信後の猶予秒数
```

## API クイックリファレンス

| メソッド | パス | 説明 |
|----------|------|------|
| POST | `/api/v1/synthesize` | テキストを音声に変換 |
| GET  | `/api/v1/voices` | 利用可能な音声の一覧 |
| GET  | `/api/v1/health` | ヘルスチェック |
| GET  | `/audio/{id}.{ext}` | 音声ファイル取得（本番では nginx が直接配信） |

### 例: 音声を生成する

```bash
curl -X POST http://127.0.0.1:8000/api/v1/synthesize \
  -H "Content-Type: application/json" \
  -d '{"text": "こんにちは", "voice": "Kyoko", "format": "m4a"}'
```

レスポンス:

```json
{
  "id": "a1b2c3d4e5f6...",
  "url": "/audio/a1b2c3d4e5f6....m4a",
  "format": "m4a",
  "voice": "Kyoko",
  "rate": null,
  "size_bytes": 12345,
  "cached": false,
  "created_at": "2026-05-16T12:00:00+00:00"
}
```

音声ファイル本体を直接受け取る場合は `?mode=file` を付ける:

```bash
curl -X POST "http://127.0.0.1:8000/api/v1/synthesize?mode=file" \
  -H "Content-Type: application/json" \
  -d '{"text": "こんにちは"}' --output hello.m4a
```

日本語音声だけを一覧する:

```bash
curl "http://127.0.0.1:8000/api/v1/voices?locale=ja"
```
