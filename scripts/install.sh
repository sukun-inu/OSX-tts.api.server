#!/usr/bin/env bash
# ================================================================
# OSX TTS API — インストーラー (macOS)
#
# 一発インストール:
#   curl -fsSL https://raw.githubusercontent.com/sukun-inu/OSX-tts.api.server/main/scripts/install.sh | bash
#
# オプション付き:
#   bash scripts/install.sh --port 8000 --host 0.0.0.0
#
# 設定値の優先順位 (高 → 低):
#   1. CLI オプション (--port, --host, ...)
#   2. 環境変数 (TTS_PORT, TTS_HOST, ...)
#   3. インストール先の .env ファイル
#   4. app/config.py のデフォルト値
# ================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────
# カラーログ
# ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
log_info()  { echo -e "${GREEN}[+]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
log_error() { echo -e "${RED}[✗]${RESET} $*" >&2; }
log_step()  { echo -e "\n${BOLD}${BLUE}━━━━ $* ━━━━${RESET}"; }
log_ok()    { echo -e "    ${GREEN}✓${RESET} $*"; }

# ──────────────────────────────────────────────────────────────────
# デフォルト設定 (環境変数で上書き可)
# ──────────────────────────────────────────────────────────────────
REPO_URL="${TTS_REPO_URL:-https://github.com/sukun-inu/OSX-tts.api.server}"
REPO_BRANCH="${TTS_REPO_BRANCH:-main}"

INSTALL_DIR="${TTS_INSTALL_DIR:-/usr/local/opt/tts-api}"
AUDIO_DIR="${TTS_AUDIO_DIR:-/usr/local/var/audio/tts-api}"
LOG_DIR="${TTS_LOG_DIR:-/usr/local/var/log/tts-api}"

# LAN からアクセスできるよう 0.0.0.0 をデフォルトにする
API_HOST="${TTS_HOST:-0.0.0.0}"
API_PORT="${TTS_PORT:-8000}"
API_PUBLIC_BASE_URL="${TTS_PUBLIC_BASE_URL:-}"
API_DEFAULT_VOICE="${TTS_DEFAULT_VOICE:-}"
API_DEFAULT_FORMAT="${TTS_DEFAULT_FORMAT:-wav}"

TTS_DAEMON_LABEL="local.tts-api"
PLIST_DIR="/Library/LaunchDaemons"
PLIST_PATH="$PLIST_DIR/${TTS_DAEMON_LABEL}.plist"

# ──────────────────────────────────────────────────────────────────
# CLI 引数解析 (最高優先)
# ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --install-dir)   INSTALL_DIR="$2";           shift 2 ;;
    --audio-dir)     AUDIO_DIR="$2";             shift 2 ;;
    --port)          API_PORT="$2";              shift 2 ;;
    --host)          API_HOST="$2";              shift 2 ;;
    --public-url)    API_PUBLIC_BASE_URL="$2";   shift 2 ;;
    --default-voice) API_DEFAULT_VOICE="$2";     shift 2 ;;
    --branch)        REPO_BRANCH="$2";           shift 2 ;;
    --repo)          REPO_URL="$2";              shift 2 ;;
    --help|-h)
      cat <<HELP
Usage: install.sh [OPTIONS]

OPTIONS:
  --install-dir DIR    アプリのインストール先         (default: $INSTALL_DIR)
  --audio-dir   DIR    音声ファイル保存先             (default: $AUDIO_DIR)
  --port        PORT   FastAPI 待ち受けポート         (default: $API_PORT)
  --host        HOST   FastAPI 待ち受けホスト         (default: $API_HOST)
  --public-url  URL    レスポンスの絶対ベースURL      (default: 空=相対パス)
  --default-voice V    デフォルト音声 (say -v)       (default: 空=システム既定)
  --branch      BR     Git ブランチ                  (default: $REPO_BRANCH)
  --repo        URL    リポジトリ URL                 (default: $REPO_URL)

環境変数でも同じ項目を設定できます (TTS_PORT, TTS_HOST, ...)。
CLI オプションが環境変数より優先されます。
HELP
      exit 0 ;;
    *) log_error "不明なオプション: $1  (--help で使い方を確認)"; exit 1 ;;
  esac
done

# ──────────────────────────────────────────────────────────────────
# macOS チェック
# ──────────────────────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  log_error "このスクリプトは macOS 専用です"; exit 1
fi

ARCH="$(uname -m)"
[[ "$ARCH" == "arm64" ]] && HOMEBREW_PREFIX="/opt/homebrew" || HOMEBREW_PREFIX="/usr/local"
log_info "アーキテクチャ: $ARCH (Homebrew prefix: $HOMEBREW_PREFIX)"

echo ""
echo -e "${BOLD}=== OSX TTS API インストーラー ===${RESET}"
echo "  インストール先 : $INSTALL_DIR"
echo "  音声ファイル   : $AUDIO_DIR"
echo "  API            : $API_HOST:$API_PORT"
echo "  Gitブランチ    : $REPO_BRANCH"
echo ""

# ──────────────────────────────────────────────────────────────────
log_step "sudo 権限の確認"
# ──────────────────────────────────────────────────────────────────
# ファイルのインストール (/usr/local/opt/, /usr/local/var/) に sudo が必要
if ! sudo -n true 2>/dev/null; then
  log_info "管理者権限が必要です (ファイルのインストールに使用)"
  sudo -v
fi
( while true; do sudo -n true; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT

# ──────────────────────────────────────────────────────────────────
log_step "既存インストールのクリーンアップ"
# ──────────────────────────────────────────────────────────────────

# --- [1] 既存 TTS LaunchDaemon (同ラベル) → bootout して plist を上書き ---
if [[ -f "$PLIST_PATH" ]]; then
  sudo launchctl bootout system "$PLIST_PATH" 2>/dev/null || true
  sudo rm -f "$PLIST_PATH"
  log_ok "既存 TTS API LaunchDaemon を停止しました"
fi

# --- [2] 旧形式: user LaunchAgent からの移行 ---
OLD_AGENT="$HOME/Library/LaunchAgents/${TTS_DAEMON_LABEL}.plist"
if [[ -f "$OLD_AGENT" ]]; then
  launchctl bootout "gui/$UID" "$OLD_AGENT" 2>/dev/null || true
  rm -f "$OLD_AGENT"
  log_ok "旧 LaunchAgent を削除しました (LaunchDaemon へ移行)"
fi

# --- [3] API ポートの占有状況 ---
PORT_PROC="$(sudo lsof -nP -iTCP:"${API_PORT}" -sTCP:LISTEN 2>/dev/null \
  | awk 'NR>1 {print $1}' | sort -u | head -1 || true)"
if [[ -n "$PORT_PROC" ]] && [[ ! "$PORT_PROC" =~ [Pp]ython ]]; then
  log_warn "ポート $API_PORT が '$PORT_PROC' によって使用中です"
  log_warn "  確認: sudo lsof -nP -iTCP:${API_PORT} -sTCP:LISTEN"
fi

# --- [4] 別パスの既存インストール (警告のみ) ---
for candidate in /usr/local/opt/tts-api /opt/tts-api /opt/homebrew/opt/tts-api; do
  if [[ -d "$candidate" ]] && [[ "$candidate" != "$INSTALL_DIR" ]]; then
    log_warn "別パスに既存インストールを検出: $candidate (不要なら: rm -rf $candidate)"
  fi
done

log_info "クリーンアップ完了"

# ──────────────────────────────────────────────────────────────────
log_step "前提条件チェック & ツール更新"
# ──────────────────────────────────────────────────────────────────

# Homebrew
if ! command -v brew &>/dev/null; then
  log_error "Homebrew が見つかりません。先にインストールしてください:"
  log_error '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi
log_info "Homebrew: $(brew --version | head -1)"

# Python 3.11+
PYTHON_BIN=""
for py in python3.13 python3.12 python3.11; do
  if command -v "$py" &>/dev/null; then
    if "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
      PYTHON_BIN="$py"; break
    fi
  fi
done
if [[ -z "$PYTHON_BIN" ]]; then
  log_warn "Python 3.11+ が見つかりません。インストールします..."
  brew install python@3.12 </dev/null
  PYTHON_BIN="python3.12"
fi
log_info "Python: $($PYTHON_BIN --version)"

# git
if command -v git &>/dev/null; then
  brew upgrade git </dev/null 2>/dev/null \
    && log_ok "git を更新しました" \
    || log_ok "git は既に最新版です"
else
  log_warn "git が見つかりません。インストールします..."
  brew install git </dev/null
fi
log_info "git: $(git --version)"

# ──────────────────────────────────────────────────────────────────
log_step "リポジトリの取得"
# ──────────────────────────────────────────────────────────────────
if [[ -d "$INSTALL_DIR/.git" ]]; then
  log_info "既存インストールを更新します: $INSTALL_DIR"
  git -C "$INSTALL_DIR" fetch origin </dev/null
  git -C "$INSTALL_DIR" checkout "$REPO_BRANCH" </dev/null
  git -C "$INSTALL_DIR" pull --ff-only origin "$REPO_BRANCH" </dev/null
else
  sudo mkdir -p "$(dirname "$INSTALL_DIR")"
  sudo git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR" </dev/null
  sudo chown -R "$(id -un):$(id -gn)" "$INSTALL_DIR"
fi
log_info "インストール先: $INSTALL_DIR"

# ──────────────────────────────────────────────────────────────────
log_step "Python 仮想環境のセットアップ"
# ──────────────────────────────────────────────────────────────────
if [[ ! -d "$INSTALL_DIR/.venv" ]]; then
  log_info "仮想環境を作成します..."
  "$PYTHON_BIN" -m venv "$INSTALL_DIR/.venv"
fi
"$INSTALL_DIR/.venv/bin/pip" install --quiet --upgrade pip </dev/null
"$INSTALL_DIR/.venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt" </dev/null
log_info "依存パッケージのインストール完了"

# ──────────────────────────────────────────────────────────────────
log_step ".env 設定ファイルの生成"
# ──────────────────────────────────────────────────────────────────
ENV_FILE="$INSTALL_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  log_warn ".env が既に存在するためスキップします: $ENV_FILE"
  log_warn "  変更後の反映: launchctl kickstart -k gui/$UID/$TTS_DAEMON_LABEL"
else
  cat > "$ENV_FILE" <<EOF
# OSX TTS API — 実行時設定 (自動生成: $(date))
# 変更後の反映: sudo launchctl kickstart -k system/${TTS_DAEMON_LABEL}
#
# 設定値の優先順位: plist EnvironmentVariables > このファイル > app/config.py デフォルト

# --- サーバー ---------------------------------------------------------------
TTS_HOST=$API_HOST
TTS_PORT=$API_PORT

# --- 音声ファイル -----------------------------------------------------------
TTS_AUDIO_DIR=$AUDIO_DIR
# 絶対 URL で返す場合のみ設定 (例: http://192.168.1.50:8000)。空=相対パス
TTS_PUBLIC_BASE_URL=$API_PUBLIC_BASE_URL

# --- 音声生成の既定値 -------------------------------------------------------
# 空 = say のシステム既定音声 (例: Kyoko)
TTS_DEFAULT_VOICE=$API_DEFAULT_VOICE
# 既定フォーマット: aiff / wav / m4a / mp3
TTS_DEFAULT_FORMAT=$API_DEFAULT_FORMAT
# 0 = say の既定速度 (語/分)
TTS_DEFAULT_RATE=0

# --- 入力制限 ---------------------------------------------------------------
TTS_MAX_TEXT_LENGTH=2000
TTS_RATE_MIN=100
TTS_RATE_MAX=400

# --- キャッシュ・クリーンアップ ---------------------------------------------
TTS_AUDIO_TTL_SECONDS=60
TTS_CLEANUP_INTERVAL_SECONDS=15
TTS_POST_SERVE_DELETE_DELAY=5

# --- 同時実行・タイムアウト -------------------------------------------------
TTS_MAX_CONCURRENT_SYNTHESIS=4
TTS_SYNTHESIS_TIMEOUT_SECONDS=30

# --- 外部コマンド -----------------------------------------------------------
TTS_FFMPEG_PATH=ffmpeg
EOF
  log_info ".env を生成しました: $ENV_FILE"
fi

INSTALL_USER="$(id -un)"
INSTALL_USER_UID="$(id -u)"

# ──────────────────────────────────────────────────────────────────
log_step "ランタイムディレクトリの準備"
# ──────────────────────────────────────────────────────────────────
sudo mkdir -p "$AUDIO_DIR" "$LOG_DIR"
sudo touch "$LOG_DIR/stdout.log" "$LOG_DIR/stderr.log"
# 音声ディレクトリはインストールユーザー所有にする。
# launchctl asuser でユーザー名前空間に委譲された say が書き込めるようにするため。
sudo chown -R "${INSTALL_USER}:wheel" "$AUDIO_DIR"
sudo chmod 755 "$AUDIO_DIR"
# ログは LaunchDaemon (root) が書き込むため root:wheel のまま
sudo chown -R root:wheel "$LOG_DIR"
sudo chmod 755 "$LOG_DIR"
log_info "音声ディレクトリ : $AUDIO_DIR"
log_info "ログディレクトリ : $LOG_DIR"

# ──────────────────────────────────────────────────────────────────
log_step "TTS API LaunchDaemon の設定"
# ──────────────────────────────────────────────────────────────────
# LaunchDaemon = root で起動してブート時から常駐。
# say コマンドはユーザーセッションが必要なため、root から
# "launchctl asuser UID" でインストールユーザーの bootstrap namespace に委譲する。

sudo tee "$PLIST_PATH" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${TTS_DAEMON_LABEL}</string>

    <!--
        root で動作させることで launchctl asuser による
        ユーザーセッション委譲が可能になる (非 root では asuser 不可)。
        TTS_SAY_USER_UID を参照して say をユーザーセッションで実行する。
    -->

    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/.venv/bin/python</string>
        <string>-m</string>
        <string>app.main</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>

    <!-- plist の EnvironmentVariables は .env より優先される -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>TTS_HOST</key>            <string>${API_HOST}</string>
        <key>TTS_PORT</key>            <string>${API_PORT}</string>
        <key>TTS_AUDIO_DIR</key>       <string>${AUDIO_DIR}</string>
        <key>PYTHONUNBUFFERED</key>    <string>1</string>
        <key>TTS_SAY_USER_UID</key>    <string>${INSTALL_USER_UID}</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG_DIR}/stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/stderr.log</string>
</dict>
</plist>
PLIST

sudo chown root:wheel "$PLIST_PATH"
sudo chmod 644 "$PLIST_PATH"
log_info "LaunchDaemon: $PLIST_PATH"
sudo launchctl bootstrap system "$PLIST_PATH"
sudo launchctl enable system/${TTS_DAEMON_LABEL}
sudo launchctl kickstart -k system/${TTS_DAEMON_LABEL}
log_info "TTS API LaunchDaemon 起動完了"

# ──────────────────────────────────────────────────────────────────
log_step "動作確認"
# ──────────────────────────────────────────────────────────────────
sleep 3

echo ""
echo "===== launchd: tts-api ====="
sudo launchctl print system/${TTS_DAEMON_LABEL} | head -30 || true

echo ""
echo "===== リッスンポート ====="
sudo lsof -nP -iTCP -sTCP:LISTEN | grep -E '[Pp]ython' || true

echo ""
echo "===== HTTP ヘルスチェック ====="
sleep 2
if curl -sf "http://127.0.0.1:${API_PORT}/api/v1/health" >/dev/null; then
  echo -e "${GREEN}OK — TTS API が応答しています${RESET}"
  curl -s "http://127.0.0.1:${API_PORT}/api/v1/health" | python3 -m json.tool 2>/dev/null || true
else
  log_warn "まだ起動中かもしれません。数秒後にお試しください:"
  log_warn "  curl http://127.0.0.1:${API_PORT}/api/v1/health"
fi

# ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}=== インストール完了! ===${RESET}"
echo ""
echo "  API エンドポイント : http://$(hostname -s):${API_PORT}/api/v1/"
echo "  Swagger UI         : http://127.0.0.1:${API_PORT}/docs"
echo "  設定ファイル       : $ENV_FILE"
echo "  ログ               : $LOG_DIR/"
echo "  音声ファイル       : $AUDIO_DIR/"
echo ""
echo "管理コマンド:"
echo "  # 状態確認"
echo "  sudo launchctl print system/$TTS_DAEMON_LABEL"
echo ""
echo "  # 再起動"
echo "  sudo launchctl kickstart -k system/$TTS_DAEMON_LABEL"
echo ""
echo "  # ログ確認"
echo "  tail -f $LOG_DIR/stderr.log"
echo ""
echo "  # アンインストール"
echo "  bash $INSTALL_DIR/scripts/uninstall.sh"
