# macOS TTS API サーバー 仕様書

| 項目 | 値 |
|------|-----|
| バージョン | 0.3.0 |
| 最終更新 | 2026-05-16 |
| ステータス | 本番稼働中 |
| ベース URL | `http://<MAC-LAN-IP>:8000` |
| Swagger UI | `http://<MAC-LAN-IP>:8000/docs` |

> **変更履歴**
> - v0.3.0 — nginx 廃止・FastAPI 直接配信、root LaunchDaemon + `launchctl asuser` 構成、`afconvert` による WAV/M4A 変換、`TTS_SAY_USER_UID` 追加
> - v0.2.0 — インストーラー追加、音声ライフサイクル変更
> - v0.1.0 — 初版

---

## 目次

1. [概要](#1-概要)
2. [システム構成](#2-システム構成)
3. [技術スタック](#3-技術スタック)
4. [ディレクトリ構成](#4-ディレクトリ構成)
5. [API 仕様](#5-api-仕様)
   - 5.1 [共通仕様](#51-共通仕様)
   - 5.2 [POST /api/v1/synthesize](#52-post-apiv1synthesize)
   - 5.3 [GET /api/v1/voices](#53-get-apiv1voices)
   - 5.4 [GET /api/v1/health](#54-get-apiv1health)
   - 5.5 [GET /audio/{id}.{ext}](#55-get-audioidext)
   - 5.6 [GET /](#56-get-)
   - 5.7 [エラーカタログ](#57-エラーカタログ)
6. [音声生成仕様](#6-音声生成仕様)
7. [キャッシュとクリーンアップ](#7-キャッシュとクリーンアップ)
8. [セキュリティ](#8-セキュリティ)
9. [同時実行制御・性能](#9-同時実行制御性能)
10. [設定（環境変数）](#10-設定環境変数)
11. [デプロイ・運用手順](#11-デプロイ運用手順)
12. [クライアント実装例](#12-クライアント実装例)
13. [Discord ボット統合（将来構想）](#13-discord-ボット統合将来構想)
14. [制約・既知の注意点](#14-制約既知の注意点)

---

## 1. 概要

### 1.1 目的

macOS 標準の `say` コマンドを音声合成エンジンとして利用し、HTTP 経由で
テキストを受け取って音声ファイルを生成・配信する API サーバーを提供する。

### 1.2 スコープ

| 区分 | 内容 |
|------|------|
| 対象 | テキスト→音声 変換 API / 音声ファイルの保存・キャッシュ・期限管理 |
| 対象外 | Discord ボット本体 / ユーザー認証（LAN 限定運用のため） |

### 1.3 想定利用シーン

LAN 内に常設した macOS マシンを TTS サーバーとし、Windows PC や Discord ボットが
テキストを送信して音声を受け取る。インターネットへの公開は想定しない。

---

## 2. システム構成

### 2.1 構成図

```
  Windows PC / Discord bot / curl
           │
           │  ① POST /api/v1/synthesize
           │     {"text": "...", "voice": "Kyoko", "format": "wav"}
           │
           ▼
  ┌─────────────────────────────────────────────────────┐
  │  FastAPI (uvicorn)  :8000                            │
  │  root LaunchDaemon として起動 (ブート時から常駐)     │
  │                                                     │
  │  ② リクエスト検証                                   │
  │  ③ 音声ID 計算 / キャッシュ確認                     │
  │  ④ say 実行 → AIFF 生成                             │
  │  ⑤ afconvert / ffmpeg で目的フォーマットへ変換       │
  │  ⑥ os.replace で原子的に保存                        │
  │  ⑦ URL or ファイル本体を返す                         │
  │                                                     │
  │  GET /audio/{id}.{ext}  → StaticFiles が配信 ⑧     │
  └─────────────────────────────────────────────────────┘
           │ launchctl asuser UID
           ▼
  /usr/bin/say  (ユーザーの CoreSpeech セッション内で実行)
           │
           ▼
  /usr/local/var/audio/tts-api/{id}.{ext}
```

### 2.2 音声生成パイプライン

```
テキスト入力
      │
      ▼
  say -f text.tmp -o .tmp-xxxx.aiff [-v voice] [-r rate]
      │
      ├─ format=aiff ──────────────────────→ os.replace → {id}.aiff
      │
      ├─ format=wav  → afconvert            → os.replace → {id}.wav
      │                -f WAVE -d LEI16 -c 1
      │
      ├─ format=m4a  → afconvert            → os.replace → {id}.m4a
      │                -f m4af -d aac -b 128000 -c 1
      │
      └─ format=mp3  → ffmpeg               → os.replace → {id}.mp3
                       -codec:a libmp3lame -qscale:a 4 -ac 1
```

### 2.3 root LaunchDaemon + launchctl asuser 設計

macOS の `say` コマンドはユーザーセッションの Mach bootstrap namespace
（CoreSpeech フレームワーク）に依存する。root プロセスから直接 `say` を
実行するとエラー -915 "Open speech channel failed" が発生する。

**解決策**:

| 要素 | 内容 |
|------|------|
| デーモン実行ユーザー | root（`UserName` キー無し） |
| say の実行方法 | `launchctl asuser <UID> /usr/bin/say ...` |
| UID の保持場所 | plist の `TTS_SAY_USER_UID` 環境変数 |
| 効果 | root 権限を保ちつつ、指定ユーザーの音声エンジンにアクセス可能 |

`launchctl asuser UID` は Mach bootstrap namespace を切り替えるが
POSIX UID は root のまま維持される。したがって:

- say は CoreSpeech サービスにアクセスできる ✓
- say は root 権限でファイルを書き込める ✓
- launchctl asuser は root でのみ実行可能（非 root では Permission Denied）✓

### 2.4 コンポーネント一覧

| コンポーネント | バイナリ | 役割 |
|----------------|---------|------|
| FastAPI (uvicorn) | `.venv/bin/python` | API 本体・静的配信 |
| say | `/usr/bin/say` | macOS 音声合成エンジン |
| afconvert | `/usr/bin/afconvert` | WAV・M4A への変換（macOS 組み込み） |
| ffmpeg | `$(which ffmpeg)` | MP3 への変換（任意・要別途インストール） |

---

## 3. 技術スタック

| 区分 | 採用技術 | バージョン |
|------|----------|-----------|
| OS | macOS | 12 Monterey 以降推奨 |
| 言語 | Python | 3.11 以上 |
| Web フレームワーク | FastAPI | 最新安定版 |
| ASGI サーバー | uvicorn | 最新安定版 |
| 設定管理 | pydantic-settings | v2 系 |
| 音声合成 | macOS `say` | OS 標準 |
| WAV/M4A 変換 | `afconvert` | macOS 組み込み |
| MP3 変換 | `ffmpeg` | 任意 |
| プロセス管理 | launchd (LaunchDaemon) | macOS 標準 |

---

## 4. ディレクトリ構成

### 4.1 リポジトリ

```
OSX-tts.api.server/
├── app/
│   ├── __init__.py     バージョン定義 (__version__ = "0.1.0")
│   ├── config.py       Settings クラス (pydantic-settings)
│   ├── schemas.py      Pydantic モデル (リクエスト/レスポンス)
│   ├── tts.py          say / afconvert / ffmpeg ラッパー
│   ├── storage.py      音声ID計算・ファイル管理・TTL クリーンアップ
│   └── main.py         FastAPI アプリ・エンドポイント定義
├── docs/
│   └── SPEC.md         本仕様書
├── scripts/
│   ├── install.sh      インストーラー
│   ├── update.sh       アップデート / --reset でフルクリーンアップ
│   ├── uninstall.sh    アンインストーラー
│   ├── test.sh         update.sh --reset への後方互換ラッパー
│   └── start.sh        開発用起動スクリプト
├── requirements.txt
├── .env.example
└── README.md
```

### 4.2 本番インストール後のパス

```
/usr/local/opt/tts-api/          アプリ本体 (git clone 先)
├── .env                          実行時設定 (install.sh が生成)
└── .venv/                        Python 仮想環境

/usr/local/var/audio/tts-api/    生成音声ファイル
  {24桁hex}.aiff / .wav / .m4a / .mp3
  .tmp-{16桁hex}.aiff             生成中の一時ファイル

/usr/local/var/log/tts-api/
  stdout.log                      uvicorn の標準出力
  stderr.log                      uvicorn のエラーログ

/Library/LaunchDaemons/
  local.tts-api.plist             LaunchDaemon 定義
```

### 4.3 モジュール責務

| モジュール | 主な関数・クラス | 責務 |
|-----------|-----------------|------|
| `config.py` | `Settings`, `get_settings()` | 環境変数読み込み・バリデーション |
| `schemas.py` | `SynthesizeRequest`, `SynthesizeResponse`, `Voice`, `HealthResponse` | Pydantic モデル定義 |
| `tts.py` | `synthesize()`, `_run_say()`, `_run_afconvert()`, `_run_ffmpeg()`, `get_voices()` | 外部コマンド実行 |
| `storage.py` | `compute_id()`, `path_for()`, `is_fresh()`, `purge_expired()`, `delete_after_serve()` | ファイル管理・キャッシュ |
| `main.py` | `app`, `synthesize()`, `voices()`, `health()` | エンドポイント定義・統合 |

---

## 5. API 仕様

### 5.1 共通仕様

| 項目 | 値 |
|------|-----|
| ベース URL | `http://<IP>:<PORT>` （ポート既定: 8000） |
| API プレフィックス | `/api/v1` |
| コンテンツタイプ | `application/json`（`mode=file` のレスポンスを除く） |
| エンコーディング | UTF-8 |
| 認証 | なし（LAN 内運用前提） |

#### 共通レスポンスヘッダ

| ヘッダ | 値 | 説明 |
|--------|----|------|
| `Content-Type` | `application/json` | JSON レスポンス時 |
| `Content-Type` | `audio/wav` 等 | `mode=file` 時（フォーマットによる） |

---

### 5.2 POST /api/v1/synthesize

テキストを音声に変換する。同一パラメータの再リクエストはキャッシュを返す。

#### クエリパラメータ

| 名前 | 型 | 必須 | 既定 | 説明 |
|------|----|------|------|------|
| `mode` | `"json"` \| `"file"` | | `"json"` | レスポンス形式 |

#### リクエストボディ

```typescript
{
  text:   string          // 必須。読み上げるテキスト
  voice?: string | null   // 音声名 (例: "Kyoko")。null/省略 = サーバー既定
  rate?:  integer | null  // 読み上げ速度 (語/分, 100〜400)。null/省略 = サーバー既定
  format?: "aiff" | "wav" | "m4a" | "mp3" | null  // 省略 = サーバー既定
}
```

**制約**:

| フィールド | 制約 | エラー |
|-----------|------|--------|
| `text` | 1 文字以上、`TTS_MAX_TEXT_LENGTH` 文字以下（既定 2000） | 400 |
| `rate` | `TTS_RATE_MIN`〜`TTS_RATE_MAX`（既定 100〜400） | 400 |
| `voice` | `GET /api/v1/voices` で取得できる名前のみ | 400 |
| `format` | `aiff` / `wav` / `m4a` / `mp3` のいずれか | 422 |
| `format=mp3` | サーバーに ffmpeg がインストールされていること | 503 |

#### レスポンス — `mode=json`（200 OK）

```typescript
{
  id:         string    // 音声ID (24桁 hex, SHA-256 由来)
  url:        string    // 取得URL ("/audio/{id}.{ext}" または絶対URL)
  format:     "aiff" | "wav" | "m4a" | "mp3"
  voice:      string | null  // 実際に使用した音声名
  rate:       integer | null // 実際に使用した読み上げ速度
  size_bytes: integer   // 音声ファイルのバイトサイズ
  cached:     boolean   // true = 既存キャッシュを再利用
  created_at: string    // ISO 8601 (UTC) 例: "2026-05-16T03:21:44.512000+00:00"
}
```

`url` は `TTS_PUBLIC_BASE_URL` の設定により変わる:

| `TTS_PUBLIC_BASE_URL` | `url` の形式 | 例 |
|-----------------------|-------------|-----|
| 空（既定） | 相対パス | `/audio/3f9a1c7e2b8d4f6a0c1e5d7b.wav` |
| `http://192.168.1.50:8000` | 絶対 URL | `http://192.168.1.50:8000/audio/3f9a...wav` |

#### レスポンス — `mode=file`（200 OK）

音声ファイル本体（バイナリストリーム）。

| フォーマット | Content-Type | Content-Disposition |
|-------------|--------------|---------------------|
| `aiff` | `audio/aiff` | `attachment; filename="{id}.aiff"` |
| `wav` | `audio/wav` | `attachment; filename="{id}.wav"` |
| `m4a` | `audio/mp4` | `attachment; filename="{id}.m4a"` |
| `mp3` | `audio/mpeg` | `attachment; filename="{id}.mp3"` |

#### リクエスト例

```bash
# JSON レスポンス (URL を受け取る)
curl -X POST http://192.168.1.50:8000/api/v1/synthesize \
  -H "Content-Type: application/json" \
  -d '{"text": "こんにちは、世界", "voice": "Kyoko", "format": "wav"}'

# ファイルを直接ダウンロード
curl -X POST "http://192.168.1.50:8000/api/v1/synthesize?mode=file" \
  -H "Content-Type: application/json" \
  -d '{"text": "こんにちは", "voice": "Kyoko", "format": "wav"}' \
  -o hello.wav
```

#### レスポンス例（`mode=json`）

```json
{
  "id": "3f9a1c7e2b8d4f6a0c1e5d7b",
  "url": "/audio/3f9a1c7e2b8d4f6a0c1e5d7b.wav",
  "format": "wav",
  "voice": "Kyoko",
  "rate": null,
  "size_bytes": 52416,
  "cached": false,
  "created_at": "2026-05-16T03:21:44.512000+00:00"
}
```

同一パラメータを再リクエストした場合（キャッシュヒット時）:

```json
{
  "id": "3f9a1c7e2b8d4f6a0c1e5d7b",
  "url": "/audio/3f9a1c7e2b8d4f6a0c1e5d7b.wav",
  "format": "wav",
  "voice": "Kyoko",
  "rate": null,
  "size_bytes": 52416,
  "cached": true,
  "created_at": "2026-05-16T03:21:44.512000+00:00"
}
```

---

### 5.3 GET /api/v1/voices

利用可能な音声の一覧を返す（`say -v '?'` の出力をパース）。

#### クエリパラメータ

| 名前 | 型 | 必須 | 説明 |
|------|----|------|------|
| `locale` | string | | ロケールの前方一致フィルタ（例: `ja` / `en` / `ja_JP`） |

#### レスポンス（200 OK）

```typescript
Array<{
  name:    string   // 音声名 (例: "Kyoko", "Samantha")
  locale:  string   // ロケール (例: "ja_JP", "en_US")
  example: string   // say が提供するサンプル文
}>
```

#### リクエスト・レスポンス例

```bash
# 全音声
curl http://192.168.1.50:8000/api/v1/voices

# 日本語音声のみ
curl "http://192.168.1.50:8000/api/v1/voices?locale=ja"
```

```json
[
  {
    "name": "Kyoko",
    "locale": "ja_JP",
    "example": "こんにちは、私の名前はKyokoです。"
  },
  {
    "name": "Otoya",
    "locale": "ja_JP",
    "example": "こんにちは、私の名前はOtoyaです。"
  }
]
```

**補足**: 音声一覧はプロセス内にキャッシュされる（ほぼ不変のため）。
キャッシュをクリアするにはデーモンを再起動する。

---

### 5.4 GET /api/v1/health

サーバーの稼働状態と外部ツールの可否を返す。

#### レスポンス（200 OK）

```typescript
{
  status:            "ok" | "degraded"   // "degraded" = say が使えない
  say_available:     boolean             // /usr/bin/say が存在するか
  ffmpeg_available:  boolean             // ffmpeg が PATH 上にあるか
  audio_count:       integer             // 現在保存されている音声ファイル数
  audio_dir:         string              // 音声ファイルの保存パス
}
```

#### レスポンス例

```bash
curl http://192.168.1.50:8000/api/v1/health
```

```json
{
  "status": "ok",
  "say_available": true,
  "ffmpeg_available": false,
  "audio_count": 3,
  "audio_dir": "/usr/local/var/audio/tts-api"
}
```

| `status` | 意味 |
|----------|------|
| `"ok"` | say が使用可能。音声生成リクエストを受け付けられる |
| `"degraded"` | say が見つからない。synthesize は 503 を返す |

---

### 5.5 GET /audio/{id}.{ext}

生成済み音声ファイルを取得する。

FastAPI の StaticFiles ミドルウェアがディスクから直接ストリーミング配信する。

| 項目 | 内容 |
|------|------|
| パスパラメータ `id` | 24 桁の hex 文字列（`synthesize` の `id` フィールド） |
| パスパラメータ `ext` | `aiff` / `wav` / `m4a` / `mp3` |
| 成功 | 200 OK + 音声バイナリ（`Accept-Ranges` 対応） |
| 不在 | 404 Not Found |
| TTL 切れ | 404 Not Found（ファイルが削除済み） |

```bash
curl http://192.168.1.50:8000/audio/3f9a1c7e2b8d4f6a0c1e5d7b.wav -o output.wav
```

---

### 5.6 GET /

サーバー情報を返す簡易エンドポイント。

#### レスポンス例

```json
{
  "name": "OSX TTS API",
  "version": "0.1.0",
  "docs": "/docs",
  "endpoints": [
    "POST /api/v1/synthesize",
    "GET /api/v1/voices",
    "GET /api/v1/health"
  ]
}
```

Swagger UI（インタラクティブな API ドキュメント）は `/docs` で参照できる。

---

### 5.7 エラーカタログ

すべてのエラーレスポンスは以下の形式:

```json
{ "detail": "エラーの説明テキスト" }
```

| HTTP | 発生条件 | `detail` の例 |
|------|---------|--------------|
| 400 | `text` が空文字 | `"text が空です"` |
| 400 | `text` が文字数超過 | `"text が長すぎます (最大 2000 文字)"` |
| 400 | `rate` が範囲外 | `"rate は 100〜400 の範囲で指定してください"` |
| 400 | 未知の `voice` 名 | `"voice 'Kyoko2' は利用できません。GET /api/v1/voices を参照してください"` |
| 422 | リクエストボディの型不正 | `[{"loc": ["body", "format"], "msg": "..."}]` |
| 500 | say が終了コード非ゼロ | `"say コマンドが失敗しました: Opening output file failed: fmt?"` |
| 500 | say が 0 バイトファイルを生成 | `"say が空の出力ファイルを生成しました。音声セッションへのアクセスに失敗している可能性があります (TTS_SAY_USER_UID の設定を確認してください)"` |
| 500 | say が出力ファイルを生成しなかった | `"say が出力ファイルを生成しませんでした"` |
| 500 | afconvert 変換失敗 | `"afconvert 変換に失敗しました (wav): ..."` |
| 500 | ffmpeg 変換失敗 | `"ffmpeg 変換に失敗しました: ..."` |
| 503 | say コマンドが見つからない | `"say コマンドが見つかりません (macOS 上でのみ動作します)"` |
| 503 | mp3 指定だが ffmpeg なし | `"mp3 形式の出力には ffmpeg が必要ですが、サーバーに見つかりません"` |
| 503 | afconvert なし (通常あり得ない) | `"mp3 出力には ffmpeg が必要ですが見つかりません"` |
| 504 | say がタイムアウト | `"音声生成がタイムアウトしました"` |
| 504 | afconvert がタイムアウト | `"wav 変換がタイムアウトしました"` |
| 504 | ffmpeg がタイムアウト | `"mp3 変換がタイムアウトしました"` |
| 504 | 音声一覧取得がタイムアウト | `"音声一覧の取得がタイムアウトしました"` |

---

## 6. 音声生成仕様

### 6.1 say の実行形式

```bash
# TTS_SAY_USER_UID が設定されている場合（root LaunchDaemon）
/bin/launchctl asuser <UID> /usr/bin/say \
  -f <テキスト一時ファイル> \
  -o <出力 AIFF パス> \
  [-v <音声名>] \
  [-r <速度>]

# 未設定の場合（開発時 / ユーザーセッション内）
/usr/bin/say \
  -f <テキスト一時ファイル> \
  -o <出力 AIFF パス> \
  [-v <音声名>] \
  [-r <速度>]
```

**設計上の決定事項**:
- テキストはコマンド引数ではなく一時ファイル（`-f`）経由で渡す → コマンドインジェクション防止
- say は常に `.aiff` で出力する → WAV/M4A を直接指定すると `"fmt?"` エラーになる macOS がある
- `-v` と `-r` は未指定時は付与しない（say のシステム既定に従う）

### 6.2 フォーマット変換

| 出力フォーマット | 変換コマンド | パラメータ詳細 |
|----------------|-------------|--------------|
| `aiff` | なし（say の出力をそのまま使用） | — |
| `wav` | `/usr/bin/afconvert` | `-f WAVE -d LEI16 -c 1`（16-bit LE PCM・モノラル） |
| `m4a` | `/usr/bin/afconvert` | `-f m4af -d aac -b 128000 -c 1`（AAC 128kbps・モノラル） |
| `mp3` | `ffmpeg` | `-codec:a libmp3lame -qscale:a 4 -ac 1`（VBR 約 165kbps・モノラル） |

`afconvert` は macOS の CoreAudio Utility Libraries に含まれる標準コマンド。
追加インストール不要。常に `/usr/bin/afconvert` として利用可能。

### 6.3 原子的書き込み

クライアントへ不完全なファイルが配信されることを防ぐため、
一時ファイルに書き出してから `os.replace`（原子的リネーム）で最終パスに移動する。

```
.tmp-a1b2c3d4e5f6g7h8.aiff  ← say が書き込む
         ↓ os.replace（原子的）
3f9a1c7e2b8d4f6a0c1e5d7b.wav  ← クライアントが取得するファイル
```

失敗時は一時ファイルを `finally` ブロックで確実に削除する。

### 6.4 利用可能な音声（ボイス）

- `say -v '?'` の出力を解析して音声リストを構築する。
- 音声リストはプロセス内にキャッシュする（不変のため）。
- リクエスト時に `voice` フィールドをホワイトリスト検証する。未知の音声名は 400。
- 日本語音声（`Kyoko`・`Otoya`）は macOS の音声設定から追加ダウンロードが必要な場合がある。

`say -v '?'` 出力例:

```
Alex                en_US    # Most people recognize me by my voice.
Kyoko               ja_JP    # こんにちは、私の名前はKyokoです。
Otoya               ja_JP    # こんにちは、私の名前はOtoyaです。
Samantha            en_US    # Hello, my name is Samantha.
```

### 6.5 読み上げ速度（rate）

| 項目 | 内容 |
|------|------|
| 単位 | 語/分（words per minute） |
| 有効範囲 | `TTS_RATE_MIN`〜`TTS_RATE_MAX`（既定 100〜400） |
| 既定値 | `TTS_DEFAULT_RATE=0` → `say` のシステム既定速度（約 175〜200 wpm） |
| `-r` フラグ | rate が `null` または `0` の場合は付与しない |

---

## 7. キャッシュとクリーンアップ

### 7.1 音声ID の計算

```python
raw = "\x1f".join([text, voice or "", str(rate) if rate is not None else "", fmt])
audio_id = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:24]
```

- `\x1f`（Unit Separator）でフィールドを区切る → テキスト内の区切り文字と衝突しない
- フォーマットもキャッシュキーに含まれる → 同一テキストの WAV と M4A は別ファイル
- voice・rate が `None` の場合は空文字列・空文字列として扱う

**例**:

| text | voice | rate | format | audio_id |
|------|-------|------|--------|----------|
| `"こんにちは"` | `"Kyoko"` | `null` | `"wav"` | `3f9a1c7e2b8d...` |
| `"こんにちは"` | `"Kyoko"` | `null` | `"m4a"` | `a7d2e4f1c8b9...` |（別ID）|
| `"こんにちは"` | `"Kyoko"` | `180` | `"wav"` | `1e5f8c2a9d7b...` |（別ID）|

### 7.2 キャッシュヒット判定

```python
def is_fresh(path: Path) -> bool:
    if not path.is_file():
        return False
    age = time.time() - path.stat().st_mtime
    return age < settings.audio_ttl_seconds  # 既定: 60 秒
```

`is_fresh` が `True` の場合、`say` を再実行せず既存ファイルを返す（`cached: true`）。

### 7.3 音声ファイルのライフサイクル

```
生成完了 (os.replace)
    │
    ├── mode=file ──→ FileResponse 送信 ──→ BackgroundTask
    │                                            │ sleep(TTS_POST_SERVE_DELETE_DELAY 秒)
    │                                            ▼
    │                                          unlink
    │
    └── mode=json ──→ GET /audio/{id}.{ext} (StaticFiles)
                           │ atime 更新 (macOS APFS では更新されない場合あり)
                           │
                      cleanup_loop (TTS_CLEANUP_INTERVAL_SECONDS 秒毎)
                           │
                           │ max(mtime, atime) + TTS_AUDIO_TTL_SECONDS < now()
                           │                   Yes
                           ▼
                         unlink
```

#### 削除ルート比較

| ルート | トリガー | 最大保持時間 |
|--------|---------|------------|
| A: 配信後削除 | `mode=file` のファイル送信完了 | `TTS_POST_SERVE_DELETE_DELAY`（既定 5 秒） |
| B: TTL クリーンアップ | `max(mtime, atime)` が TTL 超過 | `TTS_AUDIO_TTL_SECONDS + TTS_CLEANUP_INTERVAL_SECONDS`（既定 75 秒） |

#### 異常終了時の一時ファイル

`.tmp-*.aiff` は正常終了後に即座に `os.replace` または削除される。
プロセス異常終了で残存した場合も、`mtime` が TTL を超えると cleanup_loop が削除する。

---

## 8. セキュリティ

### 8.1 コマンドインジェクション対策

| 対策 | 詳細 |
|------|------|
| シェル非使用 | すべての外部コマンドを `asyncio.create_subprocess_exec` で実行（`shell=False`） |
| テキストの分離 | `say -f <tmpfile>` でテキストをファイル経由渡し。引数として展開されない |
| voice のホワイトリスト | `say -v '?'` の出力と照合。未知の値は 400 で拒否 |
| rate の型チェック | `int` 型バリデーション + 範囲チェック |

### 8.2 入力制限

| 対象 | 制限 | 設定 |
|------|------|------|
| テキスト長 | 最大 `TTS_MAX_TEXT_LENGTH` 文字（既定 2000） | `.env` |
| 読み上げ速度 | `TTS_RATE_MIN`〜`TTS_RATE_MAX`（既定 100〜400 wpm） | `.env` |
| 同時生成数 | 最大 `TTS_MAX_CONCURRENT_SYNTHESIS` プロセス（既定 4） | `.env` |
| 生成タイムアウト | `TTS_SYNTHESIS_TIMEOUT_SECONDS` 秒（既定 30） | `.env` |

### 8.3 ネットワークアクセス制御

- `TTS_HOST=0.0.0.0`（既定）で LAN に公開する。
- インターネット公開しない前提。ルーター側のファイアウォールで制御する。
- 認証機構はない。インターネット公開が必要な場合は別途 API キー認証等を追加する。

---

## 9. 同時実行制御・性能

### 9.1 セマフォ制御

`asyncio.Semaphore(TTS_MAX_CONCURRENT_SYNTHESIS)` で、同時に起動する
`say` / `afconvert` / `ffmpeg` プロセス数を制限する。

各フォーマットのプロセス数:

| フォーマット | say | afconvert | ffmpeg | 合計 (1 リクエスト) |
|-------------|-----|-----------|--------|---------------------|
| `aiff` | 1 | 0 | 0 | 1（順次） |
| `wav` | 1 | 1 | 0 | 2（順次） |
| `m4a` | 1 | 1 | 0 | 2（順次） |
| `mp3` | 1 | 0 | 1 | 2（順次） |

say と afconvert/ffmpeg は同一リクエスト内で順次実行される（並列ではない）。
4 リクエストが同時に来た場合、合計 4〜8 プロセスが並列に動く。

### 9.2 非同期 I/O の方針

| 操作 | 実装方法 | 理由 |
|------|---------|------|
| say / afconvert / ffmpeg の実行 | `asyncio.create_subprocess_exec` + `await` | イベントループをブロックしない |
| テキスト一時ファイルの書き込み | `asyncio.to_thread` | 同期 I/O をスレッドプールへ退避 |
| `os.replace` / `os.unlink` | `asyncio.to_thread` | 同様 |
| ディレクトリ走査（クリーンアップ） | `asyncio.to_thread` | 同様 |
| `/audio/` の静的配信 | Starlette StaticFiles | 内部でスレッドプール使用 |
| say / ffmpeg の存在確認 | `@cache` で起動時に一度だけ実行 | 毎リクエスト実行を避ける |

---

## 10. 設定（環境変数）

すべての設定値は接頭辞 `TTS_` 付きの環境変数で指定する。
優先順位（高 → 低）:

```
plist EnvironmentVariables  >  .env ファイル  >  config.py の既定値
```

plist で設定されている変数（`TTS_HOST`, `TTS_PORT`, `TTS_AUDIO_DIR`, `TTS_SAY_USER_UID`）は
`.env` の同名設定より優先されるため、`.env` を変更しても plist 側が勝つ。

通常の設定変更手順:

```bash
nano /usr/local/opt/tts-api/.env
sudo launchctl kickstart -k system/local.tts-api
```

### 10.1 設定一覧

#### サーバー設定

| 環境変数 | 型 | 既定値 | 設定場所 | 説明 |
|----------|-----|--------|---------|------|
| `TTS_HOST` | string | `"0.0.0.0"` | plist | FastAPI 待ち受けホスト。`0.0.0.0` = 全インターフェース（LAN 公開） |
| `TTS_PORT` | int | `8000` | plist | FastAPI 待ち受けポート |

#### 音声ファイル設定

| 環境変数 | 型 | 既定値 | 設定場所 | 説明 |
|----------|-----|--------|---------|------|
| `TTS_AUDIO_DIR` | path | `"audio"` | plist | 音声ファイル保存先。相対パスは起動時 CWD 基準で解決 |
| `TTS_PUBLIC_BASE_URL` | string | `""` | .env | レスポンス `url` の絶対 URL プレフィックス。空 = 相対パス |

#### 音声合成の既定値

| 環境変数 | 型 | 既定値 | 設定場所 | 説明 |
|----------|-----|--------|---------|------|
| `TTS_SAY_USER_UID` | string | `""` | **plist のみ** | `launchctl asuser` に渡すユーザー UID。install.sh が自動設定 |
| `TTS_DEFAULT_VOICE` | string | `""` | .env | 既定の音声名。空 = say のシステム既定 |
| `TTS_DEFAULT_RATE` | int | `0` | .env | 既定の読み上げ速度（wpm）。`0` = say の既定速度 |
| `TTS_DEFAULT_FORMAT` | string | `"wav"` | .env | 既定の出力フォーマット（`aiff`/`wav`/`m4a`/`mp3`） |

#### 入力制限

| 環境変数 | 型 | 既定値 | 設定場所 | 説明 |
|----------|-----|--------|---------|------|
| `TTS_MAX_TEXT_LENGTH` | int | `2000` | .env | テキストの最大文字数 |
| `TTS_RATE_MIN` | int | `100` | .env | rate の下限（wpm） |
| `TTS_RATE_MAX` | int | `400` | .env | rate の上限（wpm） |

#### キャッシュ・クリーンアップ

| 環境変数 | 型 | 既定値 | 設定場所 | 説明 |
|----------|-----|--------|---------|------|
| `TTS_AUDIO_TTL_SECONDS` | int | `60` | .env | `max(mtime, atime)` からファイルを保持する秒数 |
| `TTS_CLEANUP_INTERVAL_SECONDS` | int | `15` | .env | バックグラウンドクリーンアップの実行間隔（秒） |
| `TTS_POST_SERVE_DELETE_DELAY` | int | `5` | .env | `mode=file` 配信後にファイルを削除するまでの猶予（秒） |

#### 同時実行・タイムアウト

| 環境変数 | 型 | 既定値 | 設定場所 | 説明 |
|----------|-----|--------|---------|------|
| `TTS_MAX_CONCURRENT_SYNTHESIS` | int | `4` | .env | 同時に起動する say/afconvert/ffmpeg の上限プロセス数 |
| `TTS_SYNTHESIS_TIMEOUT_SECONDS` | int | `30` | .env | 1 回の音声生成・変換のタイムアウト（秒） |

#### 外部コマンド

| 環境変数 | 型 | 既定値 | 設定場所 | 説明 |
|----------|-----|--------|---------|------|
| `TTS_FFMPEG_PATH` | string | `"ffmpeg"` | .env | ffmpeg の実行パス。PATH 上にない場合は絶対パスを指定 |

---

## 11. デプロイ・運用手順

### 11.1 インストール要件

| 要件 | 必須 | 用途 |
|------|------|------|
| macOS 12 以上 | ✓ | `say`・`afconvert` が必要 |
| Homebrew | ✓ | Python のインストールに使用 |
| Python 3.11 以上 | ✓ | `install.sh` が自動インストール |
| sudo 権限 | ✓ | `/usr/local/` への書き込み・LaunchDaemon 登録 |
| ffmpeg | | `mp3` 出力時のみ。`brew install ffmpeg` |

### 11.2 一発インストール

```bash
curl -fsSL https://raw.githubusercontent.com/sukun-inu/OSX-tts.api.server/main/scripts/install.sh | bash
```

オプション付き:

```bash
curl -fsSL https://raw.githubusercontent.com/sukun-inu/OSX-tts.api.server/main/scripts/install.sh \
  | bash -s -- \
      --port 8000 \
      --public-url http://192.168.1.50:8000 \
      --default-voice Kyoko
```

`install.sh` オプション一覧:

| オプション | 既定値 | 説明 |
|-----------|--------|------|
| `--install-dir DIR` | `/usr/local/opt/tts-api` | アプリのインストール先 |
| `--audio-dir DIR` | `/usr/local/var/audio/tts-api` | 音声ファイル保存先 |
| `--port PORT` | `8000` | FastAPI 待ち受けポート |
| `--host HOST` | `0.0.0.0` | FastAPI 待ち受けホスト |
| `--public-url URL` | （空） | レスポンスの絶対ベース URL |
| `--default-voice V` | （空） | デフォルト音声名 |
| `--branch BR` | `main` | Git ブランチ |

### 11.3 LaunchDaemon の構造

install.sh が生成する plist の主要項目:

```xml
<dict>
  <key>Label</key>              <string>local.tts-api</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/opt/tts-api/.venv/bin/python</string>
    <string>-m</string>
    <string>app.main</string>
  </array>
  <key>WorkingDirectory</key>   <string>/usr/local/opt/tts-api</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TTS_HOST</key>          <string>0.0.0.0</string>
    <key>TTS_PORT</key>          <string>8000</string>
    <key>TTS_AUDIO_DIR</key>     <string>/usr/local/var/audio/tts-api</string>
    <key>TTS_SAY_USER_UID</key>  <string>501</string>  <!-- インストールユーザーの UID -->
    <key>PYTHONUNBUFFERED</key>  <string>1</string>
  </dict>
  <key>RunAtLoad</key>           <true/>
  <key>KeepAlive</key>           <true/>
  <key>StandardOutPath</key>    <string>/usr/local/var/log/tts-api/stdout.log</string>
  <key>StandardErrorPath</key>  <string>/usr/local/var/log/tts-api/stderr.log</string>
</dict>
```

`UserName` キーを持たないため root で動作し、`launchctl asuser` の実行が可能になる。

### 11.4 管理コマンド

```bash
# 状態確認
sudo launchctl print system/local.tts-api

# 再起動（.env 変更を反映する場合も）
sudo launchctl kickstart -k system/local.tts-api

# ログをリアルタイム表示
tail -f /usr/local/var/log/tts-api/stderr.log

# アップデート（コード最新化 + 依存更新 + 再起動）
bash /usr/local/opt/tts-api/scripts/update.sh

# フルクリーンアップ（再インストール用）
bash /usr/local/opt/tts-api/scripts/update.sh --reset

# アンインストール
bash /usr/local/opt/tts-api/scripts/uninstall.sh
bash /usr/local/opt/tts-api/scripts/uninstall.sh --keep-audio   # 音声ファイルを残す
bash /usr/local/opt/tts-api/scripts/uninstall.sh --yes          # 確認スキップ
```

### 11.5 動作確認

```bash
# ヘルスチェック
curl http://127.0.0.1:8000/api/v1/health | python3 -m json.tool

# 日本語音声の確認
curl "http://127.0.0.1:8000/api/v1/voices?locale=ja"

# WAV ファイルを生成して取得
curl -X POST "http://127.0.0.1:8000/api/v1/synthesize?mode=file" \
  -H "Content-Type: application/json" \
  -d '{"text": "テスト", "voice": "Kyoko", "format": "wav"}' \
  -o test.wav && afplay test.wav
```

### 11.6 開発環境

```bash
cp .env.example .env
./scripts/start.sh
# → http://127.0.0.1:8000/docs で Swagger UI が開く
```

---

## 12. クライアント実装例

### 12.1 PowerShell（Windows）

```powershell
# ファイルを直接ダウンロード（推奨）
$mac = "http://192.168.1.50:8000"
iwr "$mac/api/v1/synthesize?mode=file" `
  -Method Post -ContentType "application/json" `
  -Body '{"text":"こんにちは","voice":"Kyoko","format":"wav"}' `
  -OutFile "tts.wav"

# JSON レスポンスから URL を取得してダウンロード
$resp = Invoke-RestMethod "$mac/api/v1/synthesize" `
  -Method Post -ContentType "application/json" `
  -Body '{"text":"こんにちは","voice":"Kyoko","format":"wav"}'
Invoke-WebRequest "$mac$($resp.url)" -OutFile "tts.wav"

# ダウンロード + 自動再生
iwr "$mac/api/v1/synthesize?mode=file" `
  -Method Post -ContentType "application/json" `
  -Body '{"text":"こんにちは","voice":"Kyoko","format":"wav"}' `
  -OutFile "$env:TEMP\tts.wav"; Start-Process "$env:TEMP\tts.wav"
```

> **フォーマット推奨**: `wav` を使用する。`m4a` は Windows でコーデックが
> 必要な場合があり、`mp3` はサーバーに ffmpeg が必要。

### 12.2 curl（macOS / Linux）

```bash
MAC="http://192.168.1.50:8000"

# ファイルをダウンロードして再生
curl -X POST "$MAC/api/v1/synthesize?mode=file" \
  -H "Content-Type: application/json" \
  -d '{"text":"こんにちは","voice":"Kyoko","format":"wav"}' \
  -o /tmp/tts.wav && afplay /tmp/tts.wav

# JSON で URL を取得してダウンロード
URL=$(curl -s -X POST "$MAC/api/v1/synthesize" \
  -H "Content-Type: application/json" \
  -d '{"text":"こんにちは","voice":"Kyoko","format":"wav"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['url'])")
curl "$MAC$URL" -o /tmp/tts.wav
```

### 12.3 Python（aiohttp）

```python
import aiohttp
import asyncio

async def tts(text: str, voice: str = "Kyoko", fmt: str = "wav") -> bytes:
    async with aiohttp.ClientSession() as session:
        async with session.post(
            "http://192.168.1.50:8000/api/v1/synthesize",
            params={"mode": "file"},
            json={"text": text, "voice": voice, "format": fmt},
        ) as resp:
            resp.raise_for_status()
            return await resp.read()

audio = asyncio.run(tts("こんにちは、世界"))
with open("output.wav", "wb") as f:
    f.write(audio)
```

---

## 13. Discord ボット統合（将来構想）

### 13.1 統合フロー

```
Discord ユーザーのメッセージ
    │
    ▼
Discord ボット
    │ ① テキスト整形（メンション除去・URL短縮・文字数制限）
    │ ② POST /api/v1/synthesize → 音声 URL 取得
    ▼
TTS API サーバー（本実装）
    │ ③ 音声 URL を返す
    ▼
Discord ボット
    │ ④ ffmpeg で URL から直接ボイスチャンネルへ再生
    ▼
Discord ボイスチャンネル
```

### 13.2 ボット実装イメージ（discord.py）

```python
import aiohttp, discord

TTS_API = "http://192.168.1.50:8000"

async def speak(vc: discord.VoiceClient, text: str) -> None:
    async with aiohttp.ClientSession() as s:
        async with s.post(f"{TTS_API}/api/v1/synthesize",
                          json={"text": text, "voice": "Kyoko", "format": "wav"}) as r:
            r.raise_for_status()
            data = await r.json()
    url = data["url"]
    if url.startswith("/"):
        url = TTS_API + url
    vc.play(discord.FFmpegPCMAudio(url))
```

### 13.3 設計上の留意点

| 項目 | 推奨実装 |
|------|---------|
| 読み上げキュー | ボット側で `asyncio.Queue` 管理 |
| メッセージ整形 | メンション・絵文字・URL・コードブロックの除去 |
| 文字数制限 | API の `TTS_MAX_TEXT_LENGTH` とは別にボット側でも制限 |
| ギルド毎の設定 | 音声・速度はボット側で保持してリクエストに反映 |
| `mode=file` | URL 取得を省略してファイル本体を直接受け取る方式も可能 |

---

## 14. 制約・既知の注意点

| 制約 | 詳細 |
|------|------|
| **macOS 専用** | `say`・`afconvert` は macOS 標準コマンド。Linux / Windows では動作しない。`say` 不在時は health が `status: degraded`、synthesize は 503 |
| **Docker 不可** | `say` はホスト macOS のフレームワーク依存のため Linux コンテナ内では動作しない |
| **音声の可用性** | 利用可能な音声は macOS にインストールされたものに依存。日本語音声（Kyoko 等）は設定から追加ダウンロードが必要な場合がある |
| **mp3 は ffmpeg 必須** | `mp3` 出力には `brew install ffmpeg` が必要。未導入なら `wav` を使用 |
| **Windows での m4a** | iTunes 未導入の Windows では M4A の再生に失敗する場合がある。**Windows クライアントには `wav` を推奨** |
| **WAV の直接出力不可** | `say -o file.wav` は一部の macOS で `"fmt?"` エラーになる。本実装では `afconvert` で変換 |
| **atime 更新** | macOS APFS は `noatime` マウントが有効な場合があり、ファイル読み込み時に `atime` が更新されないことがある。その場合 TTL は `mtime`（生成時刻）基準で動作する |
| **TTS_SAY_USER_UID 更新** | インストールユーザーの UID 変更や OS 再インストール後は `install.sh` を再実行して plist を更新する |
| **認証なし** | LAN 内運用前提。インターネット公開時は API キー認証等の追加が必要 |
