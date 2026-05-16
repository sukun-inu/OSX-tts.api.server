#!/usr/bin/env bash
# ================================================================
# OSX TTS API — テスト用フルクリーンアップスクリプト
#
# インストールしたものをすべて消して白紙に戻す。
# install.sh の動作確認を繰り返す際に使う。
#
# 使い方:
#   bash scripts/test.sh
# ================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'
log_ok()   { echo -e "${GREEN}[+]${RESET} $*"; }
log_warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
log_step() { echo -e "\n${BOLD}━━━━ $* ━━━━${RESET}"; }

INSTALL_DIR="/usr/local/opt/tts-api"
AUDIO_DIR="/usr/local/var/audio/tts-api"
LOG_DIR="/usr/local/var/log/tts-api"
RUN_DIR="/usr/local/var/run/tts-api"
TTS_DAEMON_LABEL="local.tts-api"
PLIST_PATH="/Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "macOS 専用です"; exit 1
fi

echo -e "${RED}${BOLD}テスト用クリーンアップ: すべて削除します${RESET}"
echo ""
sudo -v

# ──────────────────────────────────────────────────────────────────
log_step "LaunchAgent 停止・削除"
# ──────────────────────────────────────────────────────────────────

# TTS API LaunchDaemon (現行)
if [[ -f "$PLIST_PATH" ]]; then
  sudo launchctl bootout system "$PLIST_PATH" 2>/dev/null || true
  sudo rm -f "$PLIST_PATH"
  log_ok "TTS API LaunchDaemon 停止"
fi

# 旧形式: user LaunchAgent
OLD_AGENT="$HOME/Library/LaunchAgents/${TTS_DAEMON_LABEL}.plist"
if [[ -f "$OLD_AGENT" ]]; then
  launchctl bootout "gui/$UID" "$OLD_AGENT" 2>/dev/null || true
  rm -f "$OLD_AGENT"
  log_ok "旧 LaunchAgent 削除"
fi

# nginx 関連 (残骸があれば)
while IFS= read -r -d '' plist; do
  sudo launchctl bootout system "$plist" 2>/dev/null || true
  sudo rm -f "$plist"
  log_ok "削除: $plist"
done < <(find /Library/LaunchDaemons -maxdepth 1 -name '*nginx*.plist' -print0 2>/dev/null)

# ──────────────────────────────────────────────────────────────────
log_step "ファイル・ディレクトリ削除"
# ──────────────────────────────────────────────────────────────────
for target in "$INSTALL_DIR" "$LOG_DIR" "$RUN_DIR" "$AUDIO_DIR"; do
  if [[ -e "$target" ]]; then
    sudo rm -rf "$target"
    log_ok "削除: $target"
  else
    log_warn "スキップ (存在しない): $target"
  fi
done

# ──────────────────────────────────────────────────────────────────
echo ""
log_ok "クリーンアップ完了。install.sh を再実行できます。"
