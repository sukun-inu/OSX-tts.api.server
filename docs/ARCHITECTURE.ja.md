# アーキテクチャと設定

[← README.ja.md に戻る](../README.ja.md)

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

## パッケージマネージャーの選択順位

Python と ffmpeg の導入には Homebrew か MacPorts のどちらか一方を使う。
どちらを使うかは次の順に決まる。

| 優先度 | 方法 | 場所 / 例 |
|--------|------|-----------|
| 1 (最高) | **CLI オプション** | `--pkg-manager macports` |
| 2 | **環境変数** | `TTS_PKG_MANAGER=macports bash install.sh` |
| 3 | **記録済みの値** | `/usr/local/opt/tts-api/.pkg-manager` |
| 4 (最低) | **自動判定** | 入っている方。両方あればエラーで停止 |

- 記録は `.pkg-manager` に `brew` または `macports` の1語で保存する。
  アプリの設定項目と混ざらないよう、`.env` には書かない。
- `1` か `2` で選ばれたマネージャーは、インストール／アップデートの完了時に
  `.pkg-manager` へ書き戻される。
- 両方入っていて記録もない場合は、**勝手に選ばずエラーで止まる**。
  どちらの Python を使うかで `.venv` の中身が変わるため。

### 実行ファイルの探し方

両方入っている環境では `command -v python3.12` が選んでいない側を拾いうる。
そのため、選んだマネージャーの prefix 配下を絶対パスで直接探す。

| マネージャー | prefix | Python | ffmpeg |
|---|---|---|---|
| Homebrew | `$(brew --prefix)` (`/usr/local` または `/opt/homebrew`) | `<prefix>/bin/python3.13` → `3.12` → `3.11` | `<prefix>/bin/ffmpeg` |
| MacPorts | `/opt/local` | 同上 | `/opt/local/bin/ffmpeg` |

`.env` の `TTS_FFMPEG_PATH` に**絶対パス**を書くのはこのため。LaunchDaemon の
PATH は最小限 (`/usr/bin:/bin:/usr/sbin:/sbin`) で、名前だけでは
`/opt/local/bin/ffmpeg` も `/usr/local/bin/ffmpeg` も見つけられない。

### 移行

`scripts/migrate-pkg-manager.sh --to <brew|macports>` で乗り換えられる。
`.venv` は plist の `ProgramArguments` が指す `${INSTALL_DIR}/.venv/bin/python`
のまま作り直すため、plist は変更しない。

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
