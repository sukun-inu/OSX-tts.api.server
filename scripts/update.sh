#!/usr/bin/env bash
# ================================================================
# OSX TTS API — アップデートスクリプト (macOS)
#
# 使い方:
#   bash /usr/local/opt/tts-api/scripts/update.sh
#   curl -fsSL https://raw.githubusercontent.com/sukun-inu/OSX-tts.api.server/main/scripts/update.sh | bash
#
# 実行内容:
#   1. git pull でコードを最新化
#   2. pip install で依存パッケージを更新
#   3. LaunchDaemon を再起動
#   4. ヘルスチェック
# ================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BOLD='\033[1m'; RESET='\033[0m'
log_info() { echo -e "${GREEN}[+]${RESET} $*"; }
log_warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
log_error(){ echo -e "${RED}[✗]${RESET} $*" >&2; }
log_step() { echo -e "\n${BOLD}━━━━ $* ━━━━${RESET}"; }

INSTALL_DIR="${TTS_INSTALL_DIR:-/usr/local/opt/tts-api}"
AUDIO_DIR="${TTS_AUDIO_DIR:-/usr/local/var/audio/tts-api}"
TTS_DAEMON_LABEL="local.tts-api"
API_PORT="${TTS_PORT:-8000}"

if [[ "$(uname)" != "Darwin" ]]; then
  log_error "このスクリプトは macOS 専用です"; exit 1
fi

if [[ ! -d "$INSTALL_DIR/.git" ]]; then
  log_error "インストールディレクトリが見つかりません: $INSTALL_DIR"
  log_error "先に install.sh を実行してください"
  exit 1
fi

echo -e "${BOLD}=== OSX TTS API アップデート ===${RESET}"
echo "  インストール先 : $INSTALL_DIR"
echo ""

# ──────────────────────────────────────────────────────────────────
log_step "コードの更新"
# ──────────────────────────────────────────────────────────────────
BEFORE="$(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
git -C "$INSTALL_DIR" fetch origin </dev/null
git -C "$INSTALL_DIR" pull --ff-only origin </dev/null
AFTER="$(git -C "$INSTALL_DIR" rev-parse --short HEAD)"

if [[ "$BEFORE" == "$AFTER" ]]; then
  log_info "コードは既に最新です ($AFTER)"
else
  log_info "更新しました: $BEFORE → $AFTER"
  git -C "$INSTALL_DIR" log --oneline "${BEFORE}..${AFTER}" 2>/dev/null || true
fi

# ──────────────────────────────────────────────────────────────────
log_step "依存パッケージの更新"
# ──────────────────────────────────────────────────────────────────
"$INSTALL_DIR/.venv/bin/pip" install --quiet --upgrade pip </dev/null
"$INSTALL_DIR/.venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt" </dev/null
log_info "依存パッケージ更新完了"

# ──────────────────────────────────────────────────────────────────
log_step "音声ディレクトリの権限確認"
# ──────────────────────────────────────────────────────────────────
# 旧インストール (root:wheel 755) からの移行: インストールユーザーが書き込めるよう修正する
CURRENT_USER="$(id -un)"
if [[ -d "$AUDIO_DIR" ]]; then
  AUDIO_OWNER="$(stat -f "%Su" "$AUDIO_DIR" 2>/dev/null || echo "")"
  if [[ "$AUDIO_OWNER" == "root" ]]; then
    sudo chown -R "${CURRENT_USER}:wheel" "$AUDIO_DIR"
    log_info "音声ディレクトリのオーナーを ${CURRENT_USER} に修正しました"
  else
    log_info "音声ディレクトリのオーナー: $AUDIO_OWNER (変更不要)"
  fi
fi

# ──────────────────────────────────────────────────────────────────
log_step "デーモンの再起動"
# ──────────────────────────────────────────────────────────────────
if sudo launchctl print system/${TTS_DAEMON_LABEL} &>/dev/null; then
  sudo launchctl kickstart -k system/${TTS_DAEMON_LABEL}
  log_info "LaunchDaemon を再起動しました"
else
  log_warn "LaunchDaemon が見つかりません。install.sh を実行してください"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────
log_step "動作確認"
# ──────────────────────────────────────────────────────────────────
sleep 3
if curl -sf "http://127.0.0.1:${API_PORT}/api/v1/health" >/dev/null; then
  echo -e "${GREEN}OK${RESET} — TTS API が応答しています"
  curl -s "http://127.0.0.1:${API_PORT}/api/v1/health" | python3 -m json.tool 2>/dev/null || true
else
  log_warn "応答なし。ログを確認してください:"
  log_warn "  tail -f /usr/local/var/log/tts-api/stderr.log"
fi

echo ""
echo -e "${BOLD}${GREEN}=== アップデート完了! ===${RESET}"
