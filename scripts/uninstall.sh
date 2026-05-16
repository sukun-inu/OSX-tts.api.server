#!/usr/bin/env bash
# ================================================================
# OSX TTS API — アンインストーラー (macOS)
#
# 使い方:
#   bash scripts/uninstall.sh
#   bash scripts/uninstall.sh --keep-audio    # 音声ファイルを残す
#   bash scripts/uninstall.sh --keep-nginx    # nginx デーモンを残す
#   bash scripts/uninstall.sh --yes           # 確認プロンプトをスキップ
# ================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'
log_info()  { echo -e "${GREEN}[+]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
log_step()  { echo -e "\n${BOLD}━━━━ $* ━━━━${RESET}"; }

# ──────────────────────────────────────────────────────────────────
# デフォルト (install.sh と同じ値)
# ──────────────────────────────────────────────────────────────────
INSTALL_DIR="${TTS_INSTALL_DIR:-/usr/local/opt/tts-api}"
AUDIO_DIR="${TTS_AUDIO_DIR:-/usr/local/var/audio/tts-api}"
LOG_DIR="${TTS_LOG_DIR:-/usr/local/var/log/tts-api}"
RUN_DIR="${TTS_RUN_DIR:-/usr/local/var/run/tts-api}"

NGINX_DAEMON_LABEL="local.nginx"
TTS_DAEMON_LABEL="local.tts-api"

KEEP_AUDIO=false
KEEP_NGINX=false
YES=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-audio) KEEP_AUDIO=true; shift ;;
    --keep-nginx) KEEP_NGINX=true; shift ;;
    --yes|-y)     YES=true;        shift ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --audio-dir)   AUDIO_DIR="$2";   shift 2 ;;
    --help|-h)
      cat <<HELP
Usage: uninstall.sh [OPTIONS]

OPTIONS:
  --keep-audio     音声ファイルを残す ($AUDIO_DIR)
  --keep-nginx     nginx LaunchDaemon を残す
  --yes / -y       確認プロンプトをスキップ
  --install-dir DIR  インストール先 (default: $INSTALL_DIR)
  --audio-dir   DIR  音声ファイル保存先 (default: $AUDIO_DIR)
HELP
      exit 0 ;;
    *) echo "不明なオプション: $1"; exit 1 ;;
  esac
done

# macOS チェック
if [[ "$(uname)" != "Darwin" ]]; then
  echo "このスクリプトは macOS 専用です"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────
# 確認プロンプト
# ──────────────────────────────────────────────────────────────────
if [[ "$YES" == "false" ]]; then
  echo -e "${RED}${BOLD}警告: OSX TTS API をアンインストールします${RESET}"
  echo ""
  echo "以下を削除します:"
  echo "  $INSTALL_DIR                                  (アプリ本体 + .venv)"
  echo "  $LOG_DIR                                      (ログ)"
  echo "  /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist"
  [[ "$KEEP_NGINX" == "false" ]] && \
    echo "  /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist  (nginx システムデーモン)"
  [[ "$KEEP_AUDIO" == "false" ]] && \
    echo "  $AUDIO_DIR                              (音声ファイル)"
  echo ""
  read -r -p "続けますか? [y/N] " reply </dev/tty
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "キャンセルしました"
    exit 0
  fi
fi

# sudo 確認
sudo -v

# ──────────────────────────────────────────────────────────────────
log_step "TTS API デーモンの停止・削除"
# ──────────────────────────────────────────────────────────────────
if sudo launchctl print system/${TTS_DAEMON_LABEL} &>/dev/null; then
  sudo launchctl bootout system /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist
  log_info "TTS API デーモンを停止しました"
fi
sudo rm -f /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist
log_info "削除: /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist"

# ──────────────────────────────────────────────────────────────────
log_step "nginx の処理"
# ──────────────────────────────────────────────────────────────────
if [[ "$KEEP_NGINX" == "false" ]]; then
  if sudo launchctl print system/${NGINX_DAEMON_LABEL} &>/dev/null; then
    sudo launchctl bootout system /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist
    log_info "nginx デーモンを停止しました"
  fi
  sudo rm -f /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist
  log_info "削除: /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist"
else
  log_warn "nginx デーモンは保持します (--keep-nginx)"
fi

# nginx サイト設定を削除 (残す場合はコメントアウトする)
for conf_dir in /opt/homebrew/etc/nginx/servers /usr/local/etc/nginx/servers; do
  if [[ -f "$conf_dir/tts-api.conf" ]]; then
    sudo rm -f "$conf_dir/tts-api.conf"
    log_info "削除: $conf_dir/tts-api.conf"
  fi
done

# ──────────────────────────────────────────────────────────────────
log_step "アプリファイルの削除"
# ──────────────────────────────────────────────────────────────────
if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
  log_info "削除: $INSTALL_DIR"
else
  log_warn "インストールディレクトリが見つかりません: $INSTALL_DIR"
fi

if [[ -d "$LOG_DIR" ]]; then
  sudo rm -rf "$LOG_DIR"
  log_info "削除: $LOG_DIR"
fi

if [[ -d "$RUN_DIR" ]]; then
  sudo rm -rf "$RUN_DIR"
  log_info "削除: $RUN_DIR"
fi

# ──────────────────────────────────────────────────────────────────
log_step "音声ファイルの処理"
# ──────────────────────────────────────────────────────────────────
if [[ "$KEEP_AUDIO" == "false" ]]; then
  if [[ -d "$AUDIO_DIR" ]]; then
    sudo rm -rf "$AUDIO_DIR"
    log_info "削除: $AUDIO_DIR"
  fi
else
  log_warn "音声ファイルは保持します (--keep-audio): $AUDIO_DIR"
fi

# ──────────────────────────────────────────────────────────────────
echo ""
log_info "アンインストール完了"
if [[ "$KEEP_NGINX" == "true" ]]; then
  echo ""
  log_warn "nginx デーモンは残っています。手動で停止する場合:"
  echo "  sudo launchctl bootout system /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist"
  echo "  sudo rm /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist"
fi
