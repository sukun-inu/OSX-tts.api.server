# macOS TTS API サーバー 仕様書

- バージョン: 0.1.0
- 最終更新: 2026-05-16
- ステータス: 初版（API サーバー単体。Discord ボット統合は将来構想）

---

## 目次

1. [概要](#1-概要)
2. [システム構成](#2-システム構成)
3. [技術スタック](#3-技術スタック)
4. [ディレクトリ構成](#4-ディレクトリ構成)
5. [API 仕様](#5-api-仕様)
6. [音声生成仕様](#6-音声生成仕様)
7. [nginx 構成](#7-nginx-構成)
8. [キャッシュとクリーンアップ](#8-キャッシュとクリーンアップ)
9. [セキュリティ](#9-セキュリティ)
10. [同時実行制御・性能](#10-同時実行制御性能)
11. [設定（環境変数）](#11-設定環境変数)
12. [Discord ボット統合の設計（将来構想）](#12-discord-ボット統合の設計将来構想)
13. [デプロイ・運用手順](#13-デプロイ運用手順)
14. [制約・既知の注意点](#14-制約既知の注意点)

---

## 1. 概要

### 1.1 目的

macOS 標準の `say` コマンドを音声合成エンジンとして利用し、HTTP 経由で
テキストを受け取って音声ファイルを生成・配信する API サーバーを提供する。
前段に nginx を置き、生成済みの音声ファイルを高速に配信する。

### 1.2 スコープ

| 区分 | 内容 |
|------|------|
| 対象 | テキスト→音声 変換 API / 音声ファイルの保存・キャッシュ・期限管理 / nginx 構成 |
| 対象外（将来） | Discord ボット本体 / ボットとの統合実装 / ユーザー認証（LAN 限定運用のため） |

最終的には Discord ボットのコメント読み上げシステムへ統合する想定だが、
**本仕様書および実装の対象は API サーバー単体**である。
統合を見据えた設計指針は [12 章](#12-discord-ボット統合の設計将来構想)に記す。

### 1.3 想定利用シーン

LAN 内に常設した macOS マシンを TTS サーバーとし、同一ネットワーク上の
クライアント（将来的には Discord 読み上げボット）がテキストを送信して
音声を受け取る。インターネットへの公開は想定しない。

### 1.4 用語

| 用語 | 説明 |
|------|------|
| TTS | Text-To-Speech。テキスト読み上げ・音声合成 |
| `say` | macOS 標準の音声合成コマンドラインツール |
| 音声ID | 生成パラメータから決まる一意の識別子。キャッシュキーを兼ねる |
| TTL | Time-To-Live。生成音声ファイルの保持時間 |

---

## 2. システム構成

### 2.1 構成図

```
 ┌───────────────────────────────┐
 │ クライアント                   │
 │ (将来: Discord 読み上げボット)  │
 └───────────────────────────────┘
        │                  ▲
        │ ① POST           │ ④ GET /audio/{id}.{ext}
        │   /api/v1/        │   （音声ファイル取得）
        │   synthesize      │
        ▼                  │
 ┌───────────────────────────────┐
 │ nginx                         │
 │  - /api/   → リバースプロキシ  │
 │  - /audio/ → 静的ファイル配信  │
 │  - LAN 内 IP のみ許可          │
 └───────────────────────────────┘
        │                  ▲
        │ proxy_pass        │ ディスクから直接配信
        ▼ 127.0.0.1:8000    │
 ┌───────────────────────────────┐
 │ FastAPI (uvicorn)              │
 │  - リクエスト検証              │
 │  - 音声ID 計算 / キャッシュ判定 │
 │  - say / ffmpeg 実行           │
 └───────────────────────────────┘
        │ ② say -f text -o file    │
        ▼                          │
 ┌──────────────┐                  │
 │ say / ffmpeg │ ③ 音声生成        │
 └──────────────┘                  │
        │                          │
        ▼                          │
 ┌───────────────────────────────┐ │
 │ audio/ ディレクトリ（共有）     │─┘
 │  FastAPI が書き込み、           │
 │  nginx が読み出す               │
 └───────────────────────────────┘
```

### 2.2 コンポーネント

| コンポーネント | 役割 |
|----------------|------|
| nginx | 受付窓口。`/api/` をリバースプロキシ、`/audio/` を静的配信、LAN 内 IP のみ許可 |
| FastAPI (uvicorn) | API 本体。リクエスト検証、`say` 実行、ファイル生成、キャッシュ管理 |
| `say` | macOS の音声合成エンジン |
| `ffmpeg` | `mp3` 出力時のみ使用する音声変換ツール |
| `audio/` ディレクトリ | 生成音声の保存先。FastAPI が書き込み、nginx が読み出す共有領域 |

### 2.3 処理フロー（音声生成 → 取得）

1. クライアントが `POST /api/v1/synthesize` にテキストを送信する。
2. nginx が LAN 内 IP を確認し、FastAPI へリバースプロキシする。
3. FastAPI がリクエストを検証し、パラメータから**音声ID**を計算する。
4. 同じ音声IDのファイルが既に存在し TTL 内であれば、それを再利用する（キャッシュヒット）。
5. 無ければ `say`（必要なら `ffmpeg`）を実行し `audio/` に音声ファイルを生成する。
6. FastAPI は音声ファイルの **URL を含む JSON** を返す（`mode=file` 指定時はファイル本体）。
7. クライアントは返された URL（`/audio/{id}.{ext}`）へ `GET` し、音声ファイルを取得する。
   このリクエストは nginx が**ディスクから直接配信**するため FastAPI を経由しない。

---

## 3. 技術スタック

| 区分 | 採用技術 | 備考 |
|------|----------|------|
| 実行 OS | macOS | `say` コマンドが必須 |
| 言語 | Python 3.11 以上 | 型ヒント・`X \| None` 構文を使用 |
| Web フレームワーク | FastAPI | 非同期、OpenAPI ドキュメント自動生成 |
| ASGI サーバー | uvicorn | |
| 設定管理 | pydantic-settings | 環境変数 / `.env` から型安全に読み込み |
| 音声合成 | macOS `say` | OS 標準。追加インストール不要 |
| 音声変換 | `ffmpeg` | `mp3` 出力時のみ必要（任意） |
| 前段サーバー | nginx | リバースプロキシ + 静的配信 |
| 開発環境 | Windows（コード編集）/ 実行は macOS | `say` は macOS でのみ動作 |

---

## 4. ディレクトリ構成

```
OSX-tts.api.server/
├── app/                  FastAPI アプリケーション
│   ├── __init__.py       バージョン定義
│   ├── config.py         設定（環境変数読み込み）
│   ├── schemas.py        リクエスト/レスポンススキーマ（Pydantic）
│   ├── tts.py            say / ffmpeg ラッパー、音声一覧取得
│   ├── storage.py        音声ファイル管理・キャッシュ・期限切れ削除
│   └── main.py           FastAPI アプリ本体、エンドポイント定義
├── docs/
│   └── SPEC.md           本仕様書
├── nginx/
│   └── tts-api.conf      nginx サイト設定
├── scripts/
│   └── start.sh          起動スクリプト（macOS 用）
├── audio/                生成音声の保存先（自動生成、Git 管理外）
├── requirements.txt      Python 依存パッケージ
├── .env.example          環境変数サンプル
├── .gitignore
└── README.md
```

### 4.1 モジュールの責務

| モジュール | 責務 |
|-----------|------|
| `config.py` | 環境変数からの設定読み込み。値の検証 |
| `schemas.py` | API の入出力スキーマ定義 |
| `tts.py` | `say` / `ffmpeg` のサブプロセス実行、音声一覧の取得・解析 |
| `storage.py` | 音声IDの計算、ファイルパス解決、TTL 管理、定期クリーンアップ |
| `main.py` | エンドポイント定義、リクエスト検証、各モジュールの統合 |

---

## 5. API 仕様

- ベース URL（nginx 経由）: `http://<サーバーのLAN-IP>`
- ベース URL（FastAPI 直接）: `http://127.0.0.1:8000`
- API バージョンプレフィックス: `/api/v1`
- リクエスト/レスポンス形式: JSON（`synthesize` の `mode=file` 応答を除く）
- 文字エンコーディング: UTF-8

### 5.1 POST /api/v1/synthesize

テキストを音声に変換する。

#### クエリパラメータ

| 名前 | 型 | 既定 | 説明 |
|------|----|----|------|
| `mode` | `json` \| `file` | `json` | `json`: メタデータ(URL含む)を返す / `file`: 音声ファイル本体を返す |

#### リクエストボディ（JSON）

| フィールド | 型 | 必須 | 説明 |
|-----------|----|----|------|
| `text` | string | ○ | 読み上げるテキスト（1 文字以上、最大 `TTS_MAX_TEXT_LENGTH` 文字） |
| `voice` | string | | 音声名（例: `Kyoko`）。未指定時はサーバー既定値 |
| `rate` | integer | | 読み上げ速度（語/分）。未指定時はサーバー既定値 |
| `format` | string | | 出力フォーマット `aiff` \| `wav` \| `m4a` \| `mp3`。未指定時はサーバー既定値 |

#### レスポンス（`mode=json`、200 OK）

| フィールド | 型 | 説明 |
|-----------|----|------|
| `id` | string | 音声の一意ID（キャッシュキー） |
| `url` | string | 音声ファイルの取得 URL |
| `format` | string | 実際の出力フォーマット |
| `voice` | string \| null | 実際に使用した音声名 |
| `rate` | integer \| null | 実際に使用した読み上げ速度 |
| `size_bytes` | integer | 音声ファイルのバイトサイズ |
| `cached` | boolean | 既存キャッシュを再利用した場合 `true` |
| `created_at` | string (ISO 8601) | 音声ファイルの生成日時（UTC） |

`url` は `TTS_PUBLIC_BASE_URL` 未設定時は相対パス（`/audio/xxxx.m4a`）、
設定時は絶対 URL（`http://192.168.1.50/audio/xxxx.m4a`）になる。

#### レスポンス（`mode=file`、200 OK）

音声ファイル本体（バイナリ）。`Content-Type` はフォーマットに応じる
（[6.2 節](#62-対応フォーマット)参照）。

#### リクエスト例

```bash
curl -X POST http://127.0.0.1:8000/api/v1/synthesize \
  -H "Content-Type: application/json" \
  -d '{"text": "こんにちは、世界", "voice": "Kyoko", "rate": 180, "format": "m4a"}'
```

#### レスポンス例

```json
{
  "id": "3f9a1c7e2b8d4f6a0c1e5d7b",
  "url": "/audio/3f9a1c7e2b8d4f6a0c1e5d7b.m4a",
  "format": "m4a",
  "voice": "Kyoko",
  "rate": 180,
  "size_bytes": 18745,
  "cached": false,
  "created_at": "2026-05-16T03:21:44.512000+00:00"
}
```

### 5.2 GET /api/v1/voices

利用可能な音声の一覧を返す（`say -v '?'` の結果）。

#### クエリパラメータ

| 名前 | 型 | 既定 | 説明 |
|------|----|----|------|
| `locale` | string | なし | ロケールの前方一致フィルタ（例: `ja` で日本語音声のみ） |

#### レスポンス（200 OK）

`Voice` オブジェクトの配列。

| フィールド | 型 | 説明 |
|-----------|----|------|
| `name` | string | 音声名 |
| `locale` | string | ロケール（例: `ja_JP`） |
| `example` | string | サンプル文 |

#### リクエスト例

```bash
curl "http://127.0.0.1:8000/api/v1/voices?locale=ja"
```

#### レスポンス例

```json
[
  { "name": "Kyoko", "locale": "ja_JP", "example": "こんにちは、私の名前はKyokoです。" },
  { "name": "Otoya", "locale": "ja_JP", "example": "こんにちは、私の名前はOtoyaです。" }
]
```

### 5.3 GET /api/v1/health

ヘルスチェック。`say` / `ffmpeg` の利用可否を返す。

#### レスポンス（200 OK）

| フィールド | 型 | 説明 |
|-----------|----|------|
| `status` | string | `ok` = 正常 / `degraded` = `say` 利用不可 |
| `say_available` | boolean | `say` コマンドが利用可能か |
| `ffmpeg_available` | boolean | `ffmpeg` が利用可能か（`mp3` 出力に必要） |
| `audio_count` | integer | 現在保存されている音声ファイル数 |
| `audio_dir` | string | 音声ファイルの保存ディレクトリ |

#### レスポンス例

```json
{
  "status": "ok",
  "say_available": true,
  "ffmpeg_available": false,
  "audio_count": 12,
  "audio_dir": "/Users/kawasaki/OSX-tts.api.server/audio"
}
```

### 5.4 GET /audio/{id}.{ext}

生成済み音声ファイルの取得。**本番環境では nginx がディスクから直接配信する**
（FastAPI を経由しない）。nginx を介さない直接アクセス時は FastAPI の
静的ファイルマウントがフォールバックとして応答する。

- 成功時: 200 OK + 音声ファイル本体
- ファイルが存在しない場合: 404 Not Found

### 5.5 GET /

サーバー情報（名前、バージョン、エンドポイント一覧）を返す簡易エンドポイント。
OpenAPI ドキュメント（Swagger UI）は `/docs` で参照できる。

### 5.6 エラーレスポンス

エラー時は HTTP ステータスコードと共に以下の形式の JSON を返す。

```json
{ "detail": "エラーの説明" }
```

| ステータス | 発生条件 |
|-----------|---------|
| 400 Bad Request | `text` が空 / `text` が長すぎる / `rate` が範囲外 / `voice` が不正 |
| 422 Unprocessable Entity | リクエストボディの型不正（Pydantic 検証エラー） |
| 500 Internal Server Error | `say` / `ffmpeg` の実行失敗 |
| 503 Service Unavailable | `say` が見つからない / `mp3` 指定だが `ffmpeg` が無い |
| 504 Gateway Timeout | 音声生成がタイムアウト |

---

## 6. 音声生成仕様

### 6.1 say コマンドの実行

音声生成は以下の形式で `say` を実行する（シェルを介さない直接実行）。

```
say -f <一時テキストファイル> -o <出力パス> [-v <音声名>] [-r <速度>]
```

- 読み上げテキストはコマンド引数ではなく**一時ファイル経由**（`-f`）で渡す。
  これにより引数解釈やコマンドインジェクションのリスクを排除する（[9 章](#9-セキュリティ)参照）。
- 出力フォーマットは出力パスの**拡張子**（`.aiff` / `.wav` / `.m4a`）で決まる。
- `-v` / `-r` は未指定時は付与せず、`say` のシステム既定に従う。

### 6.2 対応フォーマット

| フォーマット | 生成方法 | Content-Type | 追加ツール | 備考 |
|-------------|---------|--------------|-----------|------|
| `aiff` | `say` が直接出力 | `audio/aiff` | 不要 | 非圧縮。サイズ大 |
| `wav` | `say` が直接出力 | `audio/wav` | 不要 | 非圧縮。サイズ大 |
| `m4a` | `say` が直接出力（AAC） | `audio/mp4` | 不要 | **既定**。圧縮・軽量 |
| `mp3` | `say` で `aiff` 生成 → `ffmpeg` で変換 | `audio/mpeg` | **ffmpeg 必須** | 最も汎用的 |

`mp3` は `say` が直接出力できないため、一旦 `aiff` を生成して `ffmpeg`
（`libmp3lame`、VBR 品質 `-qscale:a 4`、モノラル）で変換する。
`ffmpeg` が見つからない場合、`mp3` 指定のリクエストは 503 を返す。

### 6.3 音声（ボイス）

- 利用可能な音声は `say -v '?'` の出力をパースして取得する。
- 結果はプロセス内でキャッシュする（音声一覧はほぼ不変のため）。
- リクエストの `voice` は音声一覧に対してホワイトリスト検証され、
  未知の音声名は 400 で拒否される。
- 日本語音声（`Kyoko`、`Otoya` 等）は macOS のバージョンによっては
  「システム設定 > アクセシビリティ > 読み上げコンテンツ」から
  追加ダウンロードが必要な場合がある。

### 6.4 読み上げ速度（rate）

- 単位は語/分（words per minute）。
- 許容範囲は `TTS_RATE_MIN`〜`TTS_RATE_MAX`（既定 100〜400）。
- 範囲外は 400 で拒否される。

---

## 7. nginx 構成

nginx は LAN 内からのアクセスを受け、2 つの役割を果たす。

### 7.1 リバースプロキシ（`/api/`、`/`）

`/api/` および `/`（`/docs` 等）へのリクエストを FastAPI（`127.0.0.1:8000`）へ
転送する。`X-Real-IP` / `X-Forwarded-For` を付与する。

### 7.2 静的配信（`/audio/`）

`/audio/` へのリクエストは FastAPI を経由せず、`alias` で指定したディレクトリから
nginx が直接ファイルを返す。これにより音声配信が高速化される。

- `alias` のパスは `TTS_AUDIO_DIR`（絶対パス）と一致させる必要がある。
- 拡張子ごとの `Content-Type` を `types` ディレクティブで指定する。
- `Cache-Control` / `Accept-Ranges` ヘッダを付与する。

### 7.3 アクセス制御

`allow` / `deny` ディレクティブでプライベート IP レンジのみ許可する。

```
allow 127.0.0.1;
allow 10.0.0.0/8;
allow 172.16.0.0/12;
allow 192.168.0.0/16;
deny  all;
```

実際のネットワークのサブネットに合わせて調整すること。
また一時ファイル（`/audio/.tmp-*` 等の隠しファイル）へのアクセスは拒否する。

設定ファイルの実体は [`nginx/tts-api.conf`](../nginx/tts-api.conf) を参照。

---

## 8. キャッシュとクリーンアップ

### 8.1 音声ID とキャッシュ

- 音声ID = `SHA-256(text + voice + rate + format)` の先頭 24 桁（16 進）。
- 同一パラメータのリクエストは同一の音声IDになり、これがキャッシュキーを兼ねる。
- 既に同一IDのファイルが存在し TTL 内であれば、`say` を再実行せず既存ファイルを返す
  （レスポンスの `cached` が `true`）。

### 8.2 ファイルの原子的書き込み

生成途中の不完全なファイルが配信されることを防ぐため、
一時ファイル（`.tmp-<乱数>.<ext>`）へ書き出してから `os.replace` で
最終ファイル名へリネームする。

### 8.3 期限切れ削除（クリーンアップ）

- 起動時にバックグラウンドタスクを開始する。
- `TTS_CLEANUP_INTERVAL_SECONDS`（既定 600 秒）ごとに、最終更新時刻が
  `TTS_AUDIO_TTL_SECONDS`（既定 3600 秒）より古いファイルを削除する。
- 異常終了で残った一時ファイルも TTL 経過後に削除される。

---

## 9. セキュリティ

### 9.1 コマンドインジェクション対策

- すべての外部コマンド（`say` / `ffmpeg`）は `asyncio.create_subprocess_exec`
  で実行し、**シェルを介さない**（`shell=True` は使用しない）。
- 読み上げテキストはコマンド引数ではなく**一時ファイル経由**（`say -f`）で渡す。
  これにより、テキストが `-` で始まる場合などの引数誤解釈や、
  インジェクションのリスクを排除する。
- `voice` は音声一覧によるホワイトリスト検証を行う。
- `rate` は整数かつ範囲チェックを行う。

### 9.2 入力サイズ制限

- `text` は `TTS_MAX_TEXT_LENGTH`（既定 2000 文字）で制限する。
- nginx 側でも `client_max_body_size 64k` でリクエストボディを制限する。

### 9.3 アクセス制御

- 本サーバーは LAN 内運用を前提とし、アプリケーションレベルの認証は持たない。
- アクセス制御は nginx の `allow` / `deny`（[7.3 節](#73-アクセス制御)）で行う。
- インターネットへ公開する場合は、API キー認証等の追加実装が別途必要
  （本仕様の対象外）。

### 9.4 リソース枯渇対策

- 同時実行数の上限（[10 章](#10-同時実行制御性能)）。
- 1 リクエストあたりの生成タイムアウト。
- 生成ファイルの TTL による自動削除（ディスク枯渇防止）。

---

## 10. 同時実行制御・性能

| 項目 | 仕組み | 設定 |
|------|--------|------|
| 同時実行数の制限 | セマフォで同時に走る `say` / `ffmpeg` プロセス数を制限 | `TTS_MAX_CONCURRENT_SYNTHESIS`（既定 4） |
| タイムアウト | 1 回の音声生成が指定秒を超えたらプロセスを kill して 504 | `TTS_SYNTHESIS_TIMEOUT_SECONDS`（既定 30） |
| キャッシュ | 同一パラメータの再生成を回避（[8 章](#8-キャッシュとクリーンアップ)） | — |
| 静的配信 | 音声ファイルは nginx が直接配信し FastAPI 負荷を軽減 | — |
| ブロッキングI/O の退避 | ファイル書き込み・`os.replace`・ディレクトリ走査を `asyncio.to_thread` でスレッドプールへ退避 | — |

### 10.1 非同期処理とブロッキング I/O

FastAPI は非同期で動作し、`say` / `ffmpeg` のサブプロセス待機中も他リクエストを
処理できる。イベントループを占有しないため、以下の方針で実装する。

- **サブプロセス実行**: `say` / `ffmpeg` は `asyncio.create_subprocess_exec` で
  非同期に起動し、`await` で完了を待つ。別プロセスとして OS が並行実行するため、
  数秒かかる音声生成中もイベントループはブロックされない。
- **ブロッキングなファイル I/O**: 一時ファイルの書き込み・`os.replace`・
  `stat`・ディレクトリ走査（クリーンアップ等）は同期 I/O のため、
  `asyncio.to_thread` でスレッドプールへ退避する。
- **外部コマンドの存在確認**: `say` / `ffmpeg` の有無（`shutil.which`）は
  実行中に変化しないため結果をキャッシュし、サーバー起動時に一度だけ評価する。
- **静的ファイル配信**: FastAPI 経由の配信（StaticFiles / FileResponse）は
  Starlette がスレッドプールでファイル I/O を行うため非ブロッキング。

---

## 11. 設定（環境変数）

すべて接頭辞 `TTS_` 付き。`.env` ファイルまたは環境変数で指定する。
未設定の項目は既定値が使われる。

| 環境変数 | 既定値 | 説明 |
|----------|--------|------|
| `TTS_HOST` | `127.0.0.1` | FastAPI の待ち受けホスト（nginx がプロキシするため localhost 推奨） |
| `TTS_PORT` | `8000` | FastAPI の待ち受けポート |
| `TTS_AUDIO_DIR` | `audio` | 音声ファイル保存先。nginx の `alias` と一致させる |
| `TTS_PUBLIC_BASE_URL` | （空） | レスポンス `url` の絶対プレフィックス。空なら相対パス |
| `TTS_DEFAULT_VOICE` | （空） | 既定の音声名。空なら `say` のシステム既定 |
| `TTS_DEFAULT_RATE` | `0` | 既定の読み上げ速度。`0` なら `say` の既定 |
| `TTS_DEFAULT_FORMAT` | `m4a` | 既定の出力フォーマット |
| `TTS_MAX_TEXT_LENGTH` | `2000` | `text` の最大文字数 |
| `TTS_RATE_MIN` | `100` | `rate` の下限 |
| `TTS_RATE_MAX` | `400` | `rate` の上限 |
| `TTS_AUDIO_TTL_SECONDS` | `3600` | 生成音声の保持時間（秒） |
| `TTS_CLEANUP_INTERVAL_SECONDS` | `600` | クリーンアップ実行間隔（秒） |
| `TTS_MAX_CONCURRENT_SYNTHESIS` | `4` | 同時実行する生成プロセス数の上限 |
| `TTS_SYNTHESIS_TIMEOUT_SECONDS` | `30` | 1 回の音声生成のタイムアウト（秒） |
| `TTS_FFMPEG_PATH` | `ffmpeg` | `ffmpeg` の実行パス |

---

## 12. Discord ボット統合の設計（将来構想）

> 本章は将来の統合に向けた設計指針であり、本実装の対象外。

### 12.1 統合フロー

```
Discord ユーザーがメッセージ投稿
        │
        ▼
Discord ボット（別プロセス / 別ホストでも可）
        │  ① メッセージ整形（メンション除去、URL 短縮、文字数制限 等）
        │  ② POST /api/v1/synthesize {text, voice, format}
        ▼
TTS API サーバー（本実装）
        │  ③ 音声URL を返す
        ▼
Discord ボット
        │  ④ 音声URL を ffmpeg 経由でボイスチャンネルへ再生
        ▼
Discord ボイスチャンネル
```

### 12.2 責務の分担

| 担当 | 責務 |
|------|------|
| TTS API（本実装） | テキスト→音声 変換、音声ファイルの配信 |
| Discord ボット（将来） | メッセージ取得・整形、読み上げキュー管理、ボイスチャンネル接続、ギルド毎の音声設定 |

### 12.3 ボット側の実装イメージ（discord.py）

```python
import aiohttp
import discord

API_BASE = "http://192.168.1.50"  # nginx のアドレス

async def speak(voice_client: discord.VoiceClient, text: str) -> None:
    # ① TTS API へテキストを送信
    async with aiohttp.ClientSession() as session:
        async with session.post(
            f"{API_BASE}/api/v1/synthesize",
            json={"text": text, "voice": "Kyoko", "format": "m4a"},
        ) as resp:
            resp.raise_for_status()
            data = await resp.json()

    # ② 返ってきた URL を ffmpeg で直接再生
    #    （url が相対パスなら API_BASE を前置する。
    #     絶対 URL にしたい場合はサーバー側で TTS_PUBLIC_BASE_URL を設定）
    audio_url = data["url"]
    if audio_url.startswith("/"):
        audio_url = API_BASE + audio_url
    source = discord.FFmpegPCMAudio(audio_url)
    voice_client.play(source)
```

### 12.4 統合時に検討すべき事項

- **読み上げキュー**: 複数メッセージの順次再生はボット側でキュー管理する。
- **メッセージ整形**: メンション・絵文字・URL・コードブロックの除去や置換。
- **文字数制限**: 長文の打ち切り（API 側の `TTS_MAX_TEXT_LENGTH` とは別に、
  ボット側でも実用的な長さに制限する）。
- **ギルド毎の設定**: 音声・速度の切り替えはボット側で保持し、リクエストに反映。
- **`mode=file` の利用**: URL 取得を挟まずファイル本体を直接受け取る方式も可能。
  ネットワーク構成に応じて選択する。

---

## 13. デプロイ・運用手順

### 13.1 前提

- macOS マシン（`say` コマンドが動作すること）
- Python 3.11 以上
- nginx（`brew install nginx`）
- `mp3` を使う場合は `ffmpeg`（`brew install ffmpeg`）

### 13.2 セットアップ

```bash
# 1. 設定ファイルを用意（必要に応じて編集）
cp .env.example .env

# 2. 起動スクリプトに実行権限を付与
chmod +x scripts/start.sh

# 3. 起動（仮想環境作成・依存インストール・起動を自動実行）
./scripts/start.sh
```

### 13.3 nginx の配置

```bash
# nginx/tts-api.conf 内の CHANGEME（audio ディレクトリの絶対パス）を修正のうえ配置
#   Apple Silicon:
cp nginx/tts-api.conf /opt/homebrew/etc/nginx/servers/tts-api.conf
#   Intel Mac:
cp nginx/tts-api.conf /usr/local/etc/nginx/servers/tts-api.conf

nginx -t            # 構文チェック
nginx -s reload     # 反映（未起動なら `nginx` で起動）
```

### 13.4 動作確認

```bash
# ヘルスチェック
curl http://127.0.0.1:8000/api/v1/health

# 音声生成
curl -X POST http://127.0.0.1:8000/api/v1/synthesize \
  -H "Content-Type: application/json" \
  -d '{"text": "テスト", "format": "m4a"}'
```

### 13.5 常駐化（任意）

`launchd`（macOS のサービス管理）に `plist` を登録すると、ログイン時の
自動起動やクラッシュ時の再起動が可能になる（本仕様の対象外）。

---

## 14. 制約・既知の注意点

- **macOS 専用**: `say` は macOS 固有のため、Linux / Windows では音声生成が
  動作しない。Windows 上ではコード編集のみ可能で、サーバー実行は macOS で行う。
  （`say` 不在時、`/api/v1/health` は `status: degraded` を返し、
  `synthesize` は 503 を返す。）
- **Docker 不可**: `say` はホスト macOS のフレームワークに依存するため、
  Linux コンテナ内では動作しない。サーバーは macOS 上で直接実行する。
- **音声の可用性**: 利用可能な音声は OS にインストールされたものに依存する。
  日本語音声は追加ダウンロードが必要な場合がある。
- **`mp3` は任意依存**: `mp3` 出力には `ffmpeg` の別途インストールが必要。
  未導入の場合は `aiff` / `wav` / `m4a` を使用する。
- **認証なし**: LAN 内運用前提。外部公開する場合は認証機構の追加が必要。
- **`say` のフォーマット指定**: 本実装は出力ファイルの拡張子でフォーマットを
  判定する。macOS のバージョンによって挙動が異なる場合は、`tts.py` の
  `_run_say` に `--file-format` / `--data-format` オプションを追加して
  明示指定する。
