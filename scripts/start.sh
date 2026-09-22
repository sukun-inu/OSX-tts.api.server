#!/usr/bin/env bash
# ================================================================
# OSX TTS API サーバー 起動スクリプト (macOS 用)
#
#   ./scripts/start.sh
#
# 仮想環境の作成・依存パッケージのインストール・サーバー起動を
# まとめて行う。ホスト/ポート等の設定は .env (なければ既定値) から読まれる。
#
# Python は、記録済み / 検出できたパッケージマネージャー (Homebrew or
# MacPorts) のものを絶対パスで使う。どちらも無ければ PATH の python3。
# ================================================================
set -euo pipefail

# プロジェクトルートへ移動
cd "$(dirname "$0")/.."

# ──────────────────────────────────────────────────────────────────
# Python の決定
# ──────────────────────────────────────────────────────────────────
# 開発用スクリプトなので、パッケージマネージャーが無くても動くようにする。
PYTHON_BIN="python3"
if [ -f "scripts/lib/pkg.sh" ]; then
  # shellcheck source=lib/pkg.sh
  . "scripts/lib/pkg.sh"
  if pkg_resolve_manager "${TTS_PKG_MANAGER:-}" "$PWD" 2>/dev/null; then
    resolved="$(pkg_python_path "$PKG_MANAGER" 2>/dev/null || true)"
    if [ -n "$resolved" ]; then
      PYTHON_BIN="$resolved"
      echo "[setup] Python: $PYTHON_BIN ($(pkg_label "$PKG_MANAGER"))"
    fi
  fi
fi

# Python 仮想環境を用意
if [ ! -d ".venv" ]; then
  echo "[setup] 仮想環境 (.venv) を作成します..."
  "$PYTHON_BIN" -m venv .venv
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
