# OSX-tts.api.server

文字を送ると、それを読み上げた音声を返してくれるサーバーです。

macOS には文章を読み上げる機能がもともと入っています（`say` コマンド）。これを
ネットワーク越しに使えるようにしたのがこのサーバーで、**Windows のPCやブラウザから
文字を送ると、Mac が読み上げた音声ファイルが返ってきます**。

Mac を1台、読み上げ担当として常時動かしておく使い方を想定しています。将来的には
Discord ボットのコメント読み上げに繋ぐ想定ですが、このリポジトリの対象は
**APIサーバー単体**です（ボット統合は未実装）。

English: [README.md](README.md)

## できること

- HTTP で文字を受け取り、音声ファイル（WAV / M4A / MP3）を生成して返す
- macOS の音声を選択可能（言語で絞り込み可）
- 生成した音声は配信後に自動削除（既定5秒後、TTL 60秒）
- 常駐デーモン（LaunchDaemon）として動作
- 同じ文章の再生成を避けるキャッシュ

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

## ドキュメント

| | |
|---|---|
| [docs/API.ja.md](docs/API.ja.md) | エンドポイント一覧と使用例 |
| [docs/SPEC.md](docs/SPEC.md) | 詳細な設計・仕様 |
| [docs/ARCHITECTURE.ja.md](docs/ARCHITECTURE.ja.md) | 全体構成、設定値の優先順位、音声ファイルのライフサイクル |
| [docs/STRUCTURE.ja.md](docs/STRUCTURE.ja.md) | リポジトリ構成と本番インストール後の配置 |
| [docs/CLIENTS.ja.md](docs/CLIENTS.ja.md) | Windows・ブラウザからの音声ダウンロード |
