#!/usr/bin/env bash
# ================================================================
# OSX TTS API サーバー 起動スクリプト (macOS 用)
#
#   ./scripts/start.sh
#
# 仮想環境の作成・依存パッケージのインストール・サーバー起動を
# まとめて行う。ホスト/ポート等の設定は .env (なければ既定値) から読まれる。
# ================================================================
set -euo pipefail

# プロジェクトルートへ移動
cd "$(dirname "$0")/.."

# Python 仮想環境を用意
if [ ! -d ".venv" ]; then
  echo "[setup] 仮想環境 (.venv) を作成します..."
  python3 -m venv .venv
fi
# shellcheck source=/dev/null
source .venv/bin/activate

# 依存パッケージをインストール
echo "[setup] 依存パッケージを確認します..."
python -m pip install --quiet --upgrade pip
python -m pip install --quiet -r requirements.txt

# サーバー起動
echo "[run] TTS API サーバーを起動します..."
exec python -m app.main
