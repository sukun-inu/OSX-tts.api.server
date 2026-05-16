#!/usr/bin/env bash
# ================================================================
# OSX TTS API — インストーラー (macOS)
#
# 一発インストール (GitHub から):
#   curl -fsSL https://raw.githubusercontent.com/sukun-inu/OSX-tts.api.server/main/scripts/install.sh | bash
#
# オプション付き:
#   bash scripts/install.sh --port 8000 --audio-dir /var/audio/tts
#
# 設定値の優先順位 (高 → 低):
#   1. このスクリプトへの CLI オプション (--port, --audio-dir, ...)
#   2. 環境変数 (TTS_PORT, TTS_AUDIO_DIR, ...)
#   3. インストール先の .env ファイル (/usr/local/opt/tts-api/.env)
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
log_ng()    { echo -e "    ${RED}✗${RESET} $*"; }
log_caution(){ echo -e "    ${YELLOW}⚠${RESET} $*"; }

# ──────────────────────────────────────────────────────────────────
# デフォルト設定 (優先度 2: 環境変数から上書き可)
# ──────────────────────────────────────────────────────────────────
REPO_URL="${TTS_REPO_URL:-https://github.com/sukun-inu/OSX-tts.api.server}"
REPO_BRANCH="${TTS_REPO_BRANCH:-main}"

INSTALL_DIR="${TTS_INSTALL_DIR:-/usr/local/opt/tts-api}"
AUDIO_DIR="${TTS_AUDIO_DIR:-/usr/local/var/audio/tts-api}"
LOG_DIR="${TTS_LOG_DIR:-/usr/local/var/log/tts-api}"
RUN_DIR="${TTS_RUN_DIR:-/usr/local/var/run/tts-api}"

API_HOST="${TTS_HOST:-127.0.0.1}"
API_PORT="${TTS_PORT:-8000}"
API_PUBLIC_BASE_URL="${TTS_PUBLIC_BASE_URL:-}"
API_DEFAULT_VOICE="${TTS_DEFAULT_VOICE:-}"
API_DEFAULT_FORMAT="${TTS_DEFAULT_FORMAT:-m4a}"

NGINX_DAEMON_LABEL="local.nginx"
TTS_DAEMON_LABEL="local.tts-api"

# ──────────────────────────────────────────────────────────────────
# CLI 引数解析 (優先度 1: 最高)
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
  --install-dir DIR    アプリのインストール先       (default: $INSTALL_DIR)
  --audio-dir   DIR    音声ファイル保存先           (default: $AUDIO_DIR)
  --port        PORT   FastAPI 待ち受けポート       (default: $API_PORT)
  --host        HOST   FastAPI 待ち受けホスト       (default: $API_HOST)
  --public-url  URL    レスポンスの絶対ベースURL    (default: 空=相対パス)
  --default-voice V    デフォルト音声 (say -v)     (default: 空=システム既定)
  --branch      BR     Git ブランチ                (default: $REPO_BRANCH)
  --repo        URL    リポジトリ URL               (default: $REPO_URL)

環境変数でも同じ項目を設定できます (TTS_INSTALL_DIR, TTS_PORT, ...)。
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
  log_error "このスクリプトは macOS 専用です"
  exit 1
fi

# Apple Silicon / Intel 判別
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  HOMEBREW_PREFIX="/opt/homebrew"
else
  HOMEBREW_PREFIX="/usr/local"
fi
log_info "アーキテクチャ: $ARCH (Homebrew prefix: $HOMEBREW_PREFIX)"

echo ""
echo "${BOLD}=== OSX TTS API インストーラー ===${RESET}"
echo "  インストール先 : $INSTALL_DIR"
echo "  音声ファイル   : $AUDIO_DIR"
echo "  API            : $API_HOST:$API_PORT"
echo "  Gitブランチ    : $REPO_BRANCH"
echo ""

# ──────────────────────────────────────────────────────────────────
log_step "sudo 権限の確認"
# ──────────────────────────────────────────────────────────────────
if ! sudo -n true 2>/dev/null; then
  log_info "管理者権限が必要です"
  sudo -v
fi
# sudo のタイムアウト延長 (長いインストールに備えて)
( while true; do sudo -n true; sleep 50; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT

# ──────────────────────────────────────────────────────────────────
log_step "既存インストールのクリーンアップ"
# ──────────────────────────────────────────────────────────────────
# 競合する設定ファイル・デーモンは上書き前に自動削除する。
# 手動解決が必要なもの (他プロセスがポートを占有など) は警告のみ出して続行。

# --- [1] Homebrew LaunchAgent で nginx が稼働中 → 自動停止・削除 ---
if brew services list 2>/dev/null | grep -E '^nginx\s+started' &>/dev/null; then
  log_info "Homebrew nginx LaunchAgent を停止します (brew services stop nginx)"
  brew services stop nginx 2>/dev/null || true
fi
if [[ -f ~/Library/LaunchAgents/homebrew.mxcl.nginx.plist ]]; then
  rm -f ~/Library/LaunchAgents/homebrew.mxcl.nginx.plist
  log_ok "削除: ~/Library/LaunchAgents/homebrew.mxcl.nginx.plist"
fi

# --- [2] 別ラベルの nginx LaunchDaemon → 自動 bootout & 削除 ---
while IFS= read -r -d '' plist; do
  label="$(basename "$plist" .plist)"
  if [[ "$label" != "$NGINX_DAEMON_LABEL" ]]; then
    log_info "競合する nginx LaunchDaemon を削除します: $plist"
    sudo launchctl bootout system "$plist" 2>/dev/null || true
    sudo rm -f "$plist"
    log_ok "削除: $plist"
  fi
done < <(find /Library/LaunchDaemons -maxdepth 1 -name '*nginx*.plist' -print0 2>/dev/null)

# --- [3] 既存の TTS LaunchDaemon → 自動 bootout (plist は後で上書き) ---
if [[ -f "/Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist" ]]; then
  EXISTING_WORKDIR="$(sed -n '/WorkingDirectory/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' \
    "/Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist" 2>/dev/null | head -1 || true)"
  if [[ -n "$EXISTING_WORKDIR" ]] && [[ "$EXISTING_WORKDIR" != "$INSTALL_DIR" ]]; then
    log_warn "既存デーモンの WorkingDirectory が異なります: $EXISTING_WORKDIR → $INSTALL_DIR (上書きします)"
  fi
  sudo launchctl bootout system /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist 2>/dev/null || true
  sudo rm -f /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist
  log_ok "既存 TTS API デーモンを停止しました"
fi

# --- [4] ポート 80 の占有状況 (自動解消できない場合は警告のみ) ---
PORT80_PROC="$(sudo lsof -nP -iTCP:80 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1}' | sort -u | head -1 || true)"
if [[ -n "$PORT80_PROC" ]] && [[ "$PORT80_PROC" != "nginx" ]]; then
  log_warn "ポート 80 が '$PORT80_PROC' によって使用中です。nginx 起動時に競合する可能性があります"
  log_warn "  確認: sudo lsof -nP -iTCP:80 -sTCP:LISTEN"
fi

# --- [5] API ポートの占有状況 ---
PORT_API_PROC="$(sudo lsof -nP -iTCP:"${API_PORT}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1}' | sort -u | head -1 || true)"
if [[ -n "$PORT_API_PROC" ]] && [[ ! "$PORT_API_PROC" =~ [Pp]ython ]]; then
  log_warn "ポート $API_PORT が '$PORT_API_PROC' によって使用中です"
  log_warn "  確認: sudo lsof -nP -iTCP:${API_PORT} -sTCP:LISTEN"
fi

# --- [6] 別パスの既存インストール (ファイルは残す、警告のみ) ---
for candidate in /usr/local/opt/tts-api /opt/tts-api /opt/homebrew/opt/tts-api; do
  if [[ -d "$candidate" ]] && [[ "$candidate" != "$INSTALL_DIR" ]]; then
    log_warn "別パスに既存インストールを検出: $candidate"
    log_warn "  不要なら: rm -rf $candidate"
  fi
done

# --- [7] 別の nginx サイト設定がポート 80 を定義している場合 (警告のみ) ---
NGINX_SERVERS_DIR="${HOMEBREW_PREFIX}/etc/nginx/servers"
if [[ -d "$NGINX_SERVERS_DIR" ]]; then
  while IFS= read -r -d '' conf; do
    [[ "$(basename "$conf")" == "tts-api.conf" ]] && continue
    if grep -qE 'listen\s+80\b' "$conf" 2>/dev/null; then
      log_warn "別の nginx サイト設定がポート 80 を使用しています: $conf"
      log_warn "  nginx -t が失敗する場合はそのファイルを無効化してください"
    fi
  done < <(find "$NGINX_SERVERS_DIR" -name '*.conf' -print0 2>/dev/null)
fi

log_info "クリーンアップ完了"

# ──────────────────────────────────────────────────────────────────
log_step "前提条件チェック & ツール更新"
# ──────────────────────────────────────────────────────────────────

# Homebrew
if ! command -v brew &>/dev/null; then
  log_error "Homebrew が見つかりません。先にインストールしてください:"
  log_error "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  exit 1
fi
log_info "Homebrew: $(brew --version | head -1)"

# Python 3.11+ — バージョン不足なら install、OK なら upgrade のみ
PYTHON_BIN=""
for py in python3.13 python3.12 python3.11; do
  if command -v "$py" &>/dev/null; then
    if "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
      PYTHON_BIN="$py"
      break
    fi
  fi
done
if [[ -z "$PYTHON_BIN" ]]; then
  log_warn "Python 3.11+ が見つかりません。インストールします..."
  brew install python@3.12
  PYTHON_BIN="python3.12"
fi
# venv はメジャー.マイナーが変わると壊れるため、Python 自体の upgrade はしない
# (venv 再作成で対応)
log_info "Python: $($PYTHON_BIN --version)"

# nginx — 既存なら upgrade、なければ install
if command -v nginx &>/dev/null; then
  log_info "nginx を最新版に更新します..."
  brew upgrade nginx 2>/dev/null \
    && log_ok "nginx を更新しました" \
    || log_ok "nginx は既に最新版です"
else
  log_warn "nginx が見つかりません。インストールします..."
  brew install nginx
fi
NGINX_BIN="$(command -v nginx)"
log_info "nginx: $($NGINX_BIN -v 2>&1)"

# nginx 設定ディレクトリを自動検出
NGINX_CONF_DIR="${HOMEBREW_PREFIX}/etc/nginx"
if [[ ! -d "$NGINX_CONF_DIR" ]]; then
  log_error "nginx 設定ディレクトリが見つかりません: $NGINX_CONF_DIR"
  exit 1
fi
log_info "nginx 設定ディレクトリ: $NGINX_CONF_DIR"

# git — 既存なら upgrade、なければ install
if command -v git &>/dev/null; then
  brew upgrade git 2>/dev/null \
    && log_ok "git を更新しました" \
    || log_ok "git は既に最新版です"
else
  log_warn "git が見つかりません。インストールします..."
  brew install git
fi
log_info "git: $(git --version)"

# ──────────────────────────────────────────────────────────────────
log_step "リポジトリの取得"
# ──────────────────────────────────────────────────────────────────
if [[ -d "$INSTALL_DIR/.git" ]]; then
  log_info "既存インストールを更新します: $INSTALL_DIR"
  git -C "$INSTALL_DIR" fetch origin
  git -C "$INSTALL_DIR" checkout "$REPO_BRANCH"
  git -C "$INSTALL_DIR" pull --ff-only origin "$REPO_BRANCH"
else
  sudo mkdir -p "$(dirname "$INSTALL_DIR")"
  sudo git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
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
"$INSTALL_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt"
log_info "依存パッケージのインストール完了"

# ──────────────────────────────────────────────────────────────────
log_step ".env 設定ファイルの生成 (優先度 3)"
# ──────────────────────────────────────────────────────────────────
ENV_FILE="$INSTALL_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  log_warn ".env が既に存在するためスキップします"
  log_warn "  手動編集: $ENV_FILE"
  log_warn "  変更後の反映: sudo launchctl kickstart -k system/$TTS_DAEMON_LABEL"
else
  cat > "$ENV_FILE" <<EOF
# OSX TTS API — 実行時設定 (自動生成: $(date))
# 変更後は以下で再起動: sudo launchctl kickstart -k system/$TTS_DAEMON_LABEL
#
# 設定値の優先順位: 環境変数 (TTS_*) > このファイル > app/config.py デフォルト

# --- サーバー ---------------------------------------------------------------
TTS_HOST=$API_HOST
TTS_PORT=$API_PORT

# --- 音声ファイル -----------------------------------------------------------
TTS_AUDIO_DIR=$AUDIO_DIR
# 絶対 URL で返す場合のみ設定 (例: http://192.168.1.50)。空=相対パス
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
# 最終アクティビティ (生成 or nginx アクセス) から削除するまでの秒数
TTS_AUDIO_TTL_SECONDS=60
# バックグラウンドクリーンアップの実行間隔 (秒)
TTS_CLEANUP_INTERVAL_SECONDS=15
# mode=file 配信完了後にファイルを削除するまでの猶予 (秒)
TTS_POST_SERVE_DELETE_DELAY=5

# --- 同時実行・タイムアウト -------------------------------------------------
TTS_MAX_CONCURRENT_SYNTHESIS=4
TTS_SYNTHESIS_TIMEOUT_SECONDS=30

# --- 外部コマンド -----------------------------------------------------------
TTS_FFMPEG_PATH=ffmpeg
EOF
  log_info ".env を生成しました: $ENV_FILE"
fi

# ──────────────────────────────────────────────────────────────────
log_step "ランタイムディレクトリの準備"
# ──────────────────────────────────────────────────────────────────
sudo mkdir -p "$AUDIO_DIR" "$LOG_DIR" "$RUN_DIR"
sudo touch "$LOG_DIR/stdout.log" "$LOG_DIR/stderr.log"
# 音声ファイルは nginx (root) と API プロセス 両方がアクセスするため 755+sticky
sudo chown -R root:wheel "$LOG_DIR" "$RUN_DIR"
sudo chmod -R 755 "$LOG_DIR" "$RUN_DIR"
sudo chmod 1777 "$AUDIO_DIR"    # world-writable + sticky bit
log_info "音声ディレクトリ : $AUDIO_DIR"
log_info "ログディレクトリ : $LOG_DIR"

# nginx 用ディレクトリ (Homebrew prefix に合わせる: Apple Silicon=/opt/homebrew, Intel=/usr/local)
NGINX_VAR_LOG="${HOMEBREW_PREFIX}/var/log/nginx"
NGINX_VAR_RUN="${HOMEBREW_PREFIX}/var/run/nginx"
sudo mkdir -p "$NGINX_VAR_LOG" "${NGINX_VAR_RUN}/client_body_temp"
sudo touch "$NGINX_VAR_LOG/access.log" "$NGINX_VAR_LOG/error.log"
sudo chown -R root:wheel "$NGINX_VAR_LOG" "$NGINX_VAR_RUN"
sudo chmod -R 755 "$NGINX_VAR_LOG" "$NGINX_VAR_RUN"

# ──────────────────────────────────────────────────────────────────
log_step "nginx の設定"
# ──────────────────────────────────────────────────────────────────

# 古い nginx LaunchDaemon を削除 (クリーンアップ済みのケースは || true で無視)
sudo launchctl bootout system /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist 2>/dev/null || true
sudo rm -f /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist

# nginx.conf を system daemon 向けに修正
NGINX_CONF="$NGINX_CONF_DIR/nginx.conf"
# user ディレクティブ削除 (root で動作するため不要)
sudo sed -i '' '/^user /d' "$NGINX_CONF"
# pid パスを /var/run に変更
if grep -q '^pid ' "$NGINX_CONF"; then
  sudo sed -i '' 's#^pid .*#pid /var/run/nginx.pid;#' "$NGINX_CONF"
else
  sudo sed -i '' $'1i\\\npid /var/run/nginx.pid;\n' "$NGINX_CONF"
fi
# Homebrew デフォルトの 8080 → 80
sudo sed -i '' 's/listen       8080;/listen       80;/' "$NGINX_CONF"

# servers/ ディレクトリの include を確認・追加
sudo mkdir -p "$NGINX_CONF_DIR/servers"
if ! grep -q 'include.*servers' "$NGINX_CONF"; then
  sudo sed -i '' '/http {/a\\    include servers/*;' "$NGINX_CONF"
  log_info "nginx.conf に include servers/*; を追加しました"
fi

# サイト設定を生成 (CHANGEME を実際のパスに展開)
sudo tee "$NGINX_CONF_DIR/servers/tts-api.conf" >/dev/null <<NGINX_CONF_CONTENT
# ================================================================
# OSX TTS API — nginx サイト設定 (自動生成: $(date))
# 手動編集後: sudo nginx -t && sudo launchctl kickstart -k system/$NGINX_DAEMON_LABEL
# ================================================================

upstream tts_api_backend {
    server ${API_HOST}:${API_PORT};
    keepalive 16;
}

server {
    listen 80;
    listen [::]:80;
    server_name _;

    # LAN 内のみ許可
    allow 127.0.0.1;
    allow 10.0.0.0/8;
    allow 172.16.0.0/12;
    allow 192.168.0.0/16;
    deny  all;

    client_max_body_size 64k;

    location ~ /\. { deny all; }

    # 音声ファイルの直接配信 (nginx が FastAPI を経由せず返す)
    location /audio/ {
        alias ${AUDIO_DIR}/;
        types {
            audio/aiff aiff;
            audio/wav  wav;
            audio/mp4  m4a;
            audio/mpeg mp3;
        }
        default_type application/octet-stream;
        add_header Cache-Control "public, max-age=3600" always;
        add_header Accept-Ranges  bytes always;
    }

    # API: FastAPI へリバースプロキシ
    location /api/ {
        proxy_pass http://tts_api_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection         "";
        proxy_set_header Host               \$host;
        proxy_set_header X-Real-IP          \$remote_addr;
        proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto  \$scheme;
        proxy_read_timeout 60s;
    }

    location / {
        proxy_pass http://tts_api_backend;
        proxy_set_header Host             \$host;
        proxy_set_header X-Real-IP        \$remote_addr;
        proxy_set_header X-Forwarded-For  \$proxy_add_x_forwarded_for;
    }
}
NGINX_CONF_CONTENT
log_info "nginx サイト設定: $NGINX_CONF_DIR/servers/tts-api.conf"

# nginx LaunchDaemon を生成
sudo tee /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${NGINX_DAEMON_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${NGINX_BIN}</string>
        <string>-g</string>
        <string>daemon off;</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${NGINX_VAR_LOG}/stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${NGINX_VAR_LOG}/stderr.log</string>
</dict>
</plist>
PLIST
sudo chown root:wheel /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist
sudo chmod 644 /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist
log_info "nginx LaunchDaemon: /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist"

# nginx 設定検証
log_info "nginx 設定を検証中..."
sudo nginx -t

# nginx デーモン起動
sudo launchctl bootstrap system /Library/LaunchDaemons/${NGINX_DAEMON_LABEL}.plist
sudo launchctl enable system/${NGINX_DAEMON_LABEL}
sudo launchctl kickstart -k system/${NGINX_DAEMON_LABEL}
log_info "nginx システムデーモン起動完了"

# ──────────────────────────────────────────────────────────────────
log_step "TTS API LaunchDaemon の設定"
# ──────────────────────────────────────────────────────────────────

# TTS API は say コマンドを使うため、インストールしたユーザーとして実行
INSTALL_USER="$(id -un)"

sudo tee /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${TTS_DAEMON_LABEL}</string>

    <!--
        say コマンドはユーザーセッション内で動作するため UserName を指定する。
        環境変数は plist > .env ファイル の順で読み込まれる。
        .env の値を上書きしたい場合は EnvironmentVariables の値を変更する。
    -->
    <key>UserName</key>
    <string>${INSTALL_USER}</string>

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
        <key>TTS_HOST</key>      <string>${API_HOST}</string>
        <key>TTS_PORT</key>      <string>${API_PORT}</string>
        <key>TTS_AUDIO_DIR</key> <string>${AUDIO_DIR}</string>
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
sudo chown root:wheel /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist
sudo chmod 644 /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist
log_info "TTS API LaunchDaemon: /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist"

sudo launchctl bootstrap system /Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist
sudo launchctl enable system/${TTS_DAEMON_LABEL}
sudo launchctl kickstart -k system/${TTS_DAEMON_LABEL}
log_info "TTS API デーモン起動完了"

# ──────────────────────────────────────────────────────────────────
log_step "動作確認"
# ──────────────────────────────────────────────────────────────────
sleep 3

echo ""
echo "===== launchd: nginx ====="
sudo launchctl print system/${NGINX_DAEMON_LABEL} | head -20 || true

echo ""
echo "===== launchd: tts-api ====="
sudo launchctl print system/${TTS_DAEMON_LABEL} | head -20 || true

echo ""
echo "===== リッスンポート ====="
sudo lsof -nP -iTCP -sTCP:LISTEN | grep -E 'nginx|Python|python' || true

echo ""
echo "===== HTTP ヘルスチェック ====="
sleep 2
if curl -sf "http://127.0.0.1/api/v1/health" >/dev/null; then
  echo -e "${GREEN}OK — TTS API が応答しています${RESET}"
else
  log_warn "まだ起動中かもしれません。数秒後にお試しください:"
  log_warn "  curl http://127.0.0.1/api/v1/health"
fi

# ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}=== インストール完了! ===${RESET}"
echo ""
echo "  設定ファイル   : $ENV_FILE"
echo "  ログ           : $LOG_DIR/"
echo "  音声ファイル   : $AUDIO_DIR/"
echo ""
echo "管理コマンド:"
echo "  # 状態確認"
echo "  sudo launchctl print system/$TTS_DAEMON_LABEL"
echo "  sudo launchctl print system/$NGINX_DAEMON_LABEL"
echo ""
echo "  # 再起動"
echo "  sudo launchctl kickstart -k system/$TTS_DAEMON_LABEL"
echo "  sudo launchctl kickstart -k system/$NGINX_DAEMON_LABEL"
echo ""
echo "  # ログ確認"
echo "  tail -f $LOG_DIR/stderr.log"
echo ""
echo "  # アンインストール"
echo "  bash $INSTALL_DIR/scripts/uninstall.sh"
