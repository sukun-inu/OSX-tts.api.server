#!/usr/bin/env bash
# ================================================================
# OSX TTS API — アンインストーラー (macOS)
#
# 使い方:
#   bash scripts/uninstall.sh
#   bash scripts/uninstall.sh --keep-audio    # 音声ファイルを残す
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

TTS_DAEMON_LABEL="local.tts-api"
PLIST_PATH="/Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist"

KEEP_AUDIO=false
YES=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --keep-audio) KEEP_AUDIO=true; shift ;;
    --yes|-y)     YES=true;        shift ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --audio-dir)   AUDIO_DIR="$2";   shift 2 ;;
    --help|-h)
      cat <<HELP
Usage: uninstall.sh [OPTIONS]

OPTIONS:
  --keep-audio     音声ファイルを残す ($AUDIO_DIR)
  --yes / -y       確認プロンプトをスキップ
  --install-dir DIR  インストール先 (default: $INSTALL_DIR)
  --audio-dir   DIR  音声ファイル保存先 (default: $AUDIO_DIR)
HELP
      exit 0 ;;
    *) echo "不明なオプション: $1"; exit 1 ;;
  esac
done

if [[ "$(uname)" != "Darwin" ]]; then
  echo "このスクリプトは macOS 専用です"; exit 1
fi

# ──────────────────────────────────────────────────────────────────
# 確認プロンプト
# ──────────────────────────────────────────────────────────────────
if [[ "$YES" == "false" ]]; then
  echo -e "${RED}${BOLD}警告: OSX TTS API をアンインストールします${RESET}"
  echo ""
  echo "以下を削除します:"
  echo "  $INSTALL_DIR                            (アプリ本体 + .venv)"
  echo "  $LOG_DIR                                (ログ)"
  echo "  $PLIST_PATH  (LaunchDaemon)"
  [[ "$KEEP_AUDIO" == "false" ]] && \
    echo "  $AUDIO_DIR                              (音声ファイル)"
  echo ""
  read -r -p "続けますか? [y/N] " reply </dev/tty
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "キャンセルしました"; exit 0
  fi
fi

sudo -v

# ──────────────────────────────────────────────────────────────────
log_step "TTS API LaunchAgent の停止・削除"
# ──────────────────────────────────────────────────────────────────

# LaunchDaemon (現行)
if [[ -f "$PLIST_PATH" ]]; then
  sudo launchctl bootout system "$PLIST_PATH" 2>/dev/null || true
  sudo rm -f "$PLIST_PATH"
  log_info "TTS API LaunchDaemon を停止しました"
fi

# 旧形式: user LaunchAgent からの移行
OLD_AGENT="$HOME/Library/LaunchAgents/${TTS_DAEMON_LABEL}.plist"
if [[ -f "$OLD_AGENT" ]]; then
  launchctl bootout "gui/$UID" "$OLD_AGENT" 2>/dev/null || true
  rm -f "$OLD_AGENT"
  log_info "旧 LaunchAgent を削除しました"
fi

# ──────────────────────────────────────────────────────────────────
log_step "アプリファイルの削除"
# ──────────────────────────────────────────────────────────────────
if [[ -d "$INSTALL_DIR" ]]; then
  sudo rm -rf "$INSTALL_DIR"
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
