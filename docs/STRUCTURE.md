# ディレクトリ構成

[← README に戻る](../README.md)

---

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
├── scripts/
│   ├── install.sh        本番インストーラー (macOS)
│   ├── update.sh         アップデートスクリプト
│   ├── uninstall.sh      アンインストーラー
│   ├── test.sh           全クリーンアップ（再インストール用）
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

/usr/local/var/audio/tts-api/        ← 生成音声ファイル (FastAPI が直接配信)
/usr/local/var/log/tts-api/          ← TTS API ログ (stdout/stderr)

/Library/LaunchDaemons/
└── local.tts-api.plist              ← TTS API 常駐デーモン (root で起動)
```
