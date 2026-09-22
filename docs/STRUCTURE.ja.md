# ディレクトリ構成

[← README.ja.md に戻る](../README.ja.md)

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
│   ├── lib/
│   │   └── pkg.sh        パッケージマネージャー共通ライブラリ
│   │                     (Homebrew / MacPorts の検出・選択・パス解決)
│   ├── install.sh        本番インストーラー (macOS)
│   ├── update.sh         アップデートスクリプト
│   ├── uninstall.sh      アンインストーラー
│   ├── migrate-pkg-manager.sh  Homebrew ⇄ MacPorts の移行
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
├── .pkg-manager                     ← 使用中のパッケージマネージャーの記録
│                                       (中身は "brew" か "macports" の1語)
├── backup/<日時>/                   ← 移行スクリプトのバックアップ
│                                       (.env / plist / .pkg-manager)
├── .venv.bak-<日時>/                ← 移行スクリプトが退避した旧仮想環境
└── .venv/                           ← Python 仮想環境

/usr/local/var/audio/tts-api/        ← 生成音声ファイル (FastAPI が直接配信)
/usr/local/var/log/tts-api/          ← TTS API ログ (stdout/stderr)

/Library/LaunchDaemons/
└── local.tts-api.plist              ← TTS API 常駐デーモン (root で起動)
```

---

## パッケージマネージャー関連のファイル

| ファイル | 役割 | 消してよいか |
|---|---|---|
| `.pkg-manager` | 使用中のマネージャー (`brew` / `macports`) の記録 | 消すと自動判定に戻る |
| `backup/<日時>/` | 移行スクリプトが取った `.env` / plist / `.pkg-manager` のバックアップ | 移行後に問題がなければ削除可 |
| `.venv.bak-<日時>/` | 移行前の仮想環境（退避したもの） | 移行後に問題がなければ削除可 |

いずれも `.gitignore` に入っているため、`git pull` での更新を邪魔しない。

> **注意**: 既定のインストール先 `/usr/local/opt` と `/usr/local/var` は、
> Intel Mac で Homebrew が使うフォルダと同じ場所にある。Homebrew を
> アンインストールする前に、アンインストーラーのドライラン機能で
> tts-api のフォルダが削除対象に含まれていないことを確認し、
> `/usr/local/opt/tts-api/.env` をバックアップしておくこと。
