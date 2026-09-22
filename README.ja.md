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
| Homebrew **または** MacPorts | Python・ffmpeg の導入に使用。どちらか一方でよい |
| Python 3.11 以上 | API サーバー実行。無ければインストーラーが入れる |
| ffmpeg | `mp3` 形式を使う場合のみ |

> Homebrew と MacPorts のどちらでも動く。どちらを使っているかは
> `/usr/local/opt/tts-api/.pkg-manager` に記録され、以後はその記録に従う。

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

# パッケージマネージャーを指定する場合
curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash -s -- \
  --pkg-manager macports
```

`--pkg-manager` には `brew` / `macports` / `auto` を指定できる。既定は `auto`。

| 状況 | `auto` の動作 |
|------|--------------|
| 記録 (`.pkg-manager`) がある | 記録されている方を使う |
| 片方だけ入っている | そちらを使う |
| 両方入っていて記録がない | **勝手に選ばずエラーで止まる**（`--pkg-manager` で指定する） |
| どちらも入っていない | 両方の導入方法を案内してエラーで止まる |

環境変数 `TTS_PKG_MANAGER` でも指定できる。優先順位は
`--pkg-manager` > `TTS_PKG_MANAGER` > 記録 > 自動判定。

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

### パッケージマネージャーを乗り換える (Homebrew ⇄ MacPorts)

移行先のパッケージマネージャーを先にインストールしてから、次を実行する。

```bash
# まず何が起きるか確認する (何も変更しない)
bash /usr/local/opt/tts-api/scripts/migrate-pkg-manager.sh --to macports --dry-run

# 実行する
bash /usr/local/opt/tts-api/scripts/migrate-pkg-manager.sh --to macports

# 逆向き (MacPorts → Homebrew) も同じ
bash /usr/local/opt/tts-api/scripts/migrate-pkg-manager.sh --to brew
```

やること:

1. 移行先の Python を用意する（無ければインストール）
2. `.env` ・ plist ・ `.pkg-manager` を `backup/<日時>/` にバックアップ
3. サービスを止め、`.venv` を `.venv.bak-<日時>` に退避（削除しない）
4. 移行先の Python で `.venv` を同じ場所に作り直す
5. `.env` の `TTS_FFMPEG_PATH` を移行先の絶対パスに更新する
   （移行元配下の絶対パスか `ffmpeg` の場合のみ。独自に設定した値は変更しない）
6. サービスを起動し、`/api/v1/health` で確認する

途中で失敗した場合は自動で元に戻し、元のパッケージマネージャーのまま
サーバーが動き続ける。ポート番号などの `.env` の設定はそのまま保たれる。

移行元のパッケージマネージャー本体と、そこから入れた python / ffmpeg は
**アンインストールしない**。削除するかどうかは自分で判断すること。

> **Homebrew をアンインストールする前に**
>
> 既定のインストール先 `/usr/local/opt/tts-api` と `/usr/local/var/...` は、
> Intel Mac で Homebrew が使うフォルダと同じ場所にある。Homebrew の
> アンインストーラーがこれらを巻き込んで消してしまう可能性がある。
>
> 1. Homebrew 公式アンインストーラーのドライランで、tts-api のフォルダが
>    削除対象に含まれていないことを確認する
>
>    ```bash
>    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" -- --dry-run
>    ```
>
> 2. `/usr/local/opt/tts-api/.env` を別の場所にバックアップしておく
>
> （ここでの「アンインストーラー」は Homebrew のものであり、
> 本リポジトリの `scripts/uninstall.sh` ではない）

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
