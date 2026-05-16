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
NGINX_DAEMON_LABEL="local.nginx"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "macOS 専用です"; exit 1
fi

echo -e "${RED}${BOLD}テスト用クリーンアップ: すべて削除します${RESET}"
echo ""
sudo -v

# ──────────────────────────────────────────────────────────────────
log_step "LaunchDaemon 停止・削除"
# ──────────────────────────────────────────────────────────────────

# TTS API
if sudo launchctl print system/${TTS_DAEMON_LABEL} &>/dev/null; then
  sudo launchctl bootout system /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist 2>/dev/null || true
  log_ok "TTS API デーモン停止"
fi
sudo rm -f /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist
log_ok "削除: local.tts-api.plist"

# nginx (ラベル違いも含めて全部消す)
while IFS= read -r -d '' plist; do
  label="$(basename "$plist" .plist)"
  sudo launchctl bootout system "$plist" 2>/dev/null || true
  sudo rm -f "$plist"
  log_ok "削除: $plist"
done < <(find /Library/LaunchDaemons -maxdepth 1 -name '*nginx*.plist' -print0 2>/dev/null)

# ──────────────────────────────────────────────────────────────────
log_step "nginx サイト設定削除"
# ──────────────────────────────────────────────────────────────────
for conf_dir in /opt/homebrew/etc/nginx/servers /usr/local/etc/nginx/servers; do
  if [[ -f "$conf_dir/tts-api.conf" ]]; then
    sudo rm -f "$conf_dir/tts-api.conf"
    log_ok "削除: $conf_dir/tts-api.conf"
  fi
done

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
