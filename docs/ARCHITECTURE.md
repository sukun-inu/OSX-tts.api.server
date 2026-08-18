# アーキテクチャと設定

[← README に戻る](../README.md)

---

## アーキテクチャ概要

```
クライアント (ブラウザ / PowerShell / Discord bot)
        │
        │ POST /api/v1/synthesize
        ▼
 FastAPI (uvicorn) ─── root LaunchDaemon として起動
        │                        │
        │ launchctl asuser UID   │ GET /audio/{id}.{ext}
        ▼                        │ (StaticFiles で直接配信)
  say コマンド                   │
  (ユーザーセッション内で実行)    │
        │                        │
        ▼                        │
 /usr/local/var/audio/tts-api/ ──┘
```

**ポイント**: デーモンは root で動作し、`say` コマンドのみ `launchctl asuser UID` を
通じてインストールユーザーの音声セッション (CoreSpeech) へ委譲する。
これにより、ログイン不要でブート直後から `say` が音声を生成できる。

## 設定値の優先順位

| 優先度 | 方法 | 場所 / 例 |
|--------|------|-----------|
| 1 (最高) | **CLI オプション** (install 時のみ) | `--port 9000` |
| 2 | **環境変数** | `TTS_PORT=9000 bash install.sh` |
| 3 | **LaunchDaemon の EnvironmentVariables** | `/Library/LaunchDaemons/local.tts-api.plist` |
| 4 | **.env ファイル** | `/usr/local/opt/tts-api/.env` |
| 5 (最低) | **app/config.py のデフォルト値** | コード内の初期値 |

> **通常の設定変更**: `.env` を直接編集 → `sudo launchctl kickstart -k system/local.tts-api`

---

## 音声ファイルのライフサイクル

生成した音声ファイルは自動削除される。ディスクを圧迫しない設計。

| ルート | タイミング | 詳細 |
|--------|-----------|------|
| **配信後削除** | ファイル送信完了の約5秒後 | `?mode=file` で FastAPI が直接返した場合 |
| **TTL 削除** | 最終アクティビティから60秒後 | 15秒ごとのバックグラウンドが `max(mtime, atime) + 60s` を超えたファイルを削除 |

各タイミングは `.env` で調整できる:

```env
TTS_AUDIO_TTL_SECONDS=60          # 最終アクセスから何秒で消すか
TTS_CLEANUP_INTERVAL_SECONDS=15   # バックグラウンドの掃除間隔
TTS_POST_SERVE_DELETE_DELAY=5     # mode=file 配信後の猶予秒数
```
