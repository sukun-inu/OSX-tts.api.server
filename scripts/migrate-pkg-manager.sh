#!/usr/bin/env bash
# ================================================================
# OSX TTS API — パッケージマネージャー移行スクリプト (macOS)
#
# Homebrew と MacPorts の間で、インストール済みの TTS API を移行する。
#
# 使い方:
#   bash scripts/migrate-pkg-manager.sh --to macports
#   bash scripts/migrate-pkg-manager.sh --to brew
#   bash scripts/migrate-pkg-manager.sh --to macports --dry-run
#
# やること:
#   .venv を移行先の Python で作り直し、.env の ffmpeg パスと
#   .pkg-manager の記録を更新して、サービスを起動し直す。
#
# やらないこと:
#   移行元のパッケージマネージャー本体や、そのパッケージ (python / ffmpeg)
#   はアンインストールしない。削除の判断はユーザーに任せる。
#
# 途中で失敗した場合は、退避した .venv とバックアップした .env /
# .pkg-manager を自動で元に戻し、サーバーを再起動する。
#
# 【制約】bash 3.2 で動くこと (macOS 標準の /bin/bash)。
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
# 既定値 (install.sh と同じ)
# ──────────────────────────────────────────────────────────────────
INSTALL_DIR="${TTS_INSTALL_DIR:-/usr/local/opt/tts-api}"
LOG_DIR="${TTS_LOG_DIR:-/usr/local/var/log/tts-api}"
TTS_DAEMON_LABEL="local.tts-api"
PLIST_PATH="/Library/LaunchDaemons/${TTS_DAEMON_LABEL}.plist"

TO_MANAGER=""
DRY_RUN=false
KEEP_BACKUP=false
API_PORT="${TTS_PORT:-}"

# ──────────────────────────────────────────────────────────────────
# CLI 引数
# ──────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --to)          TO_MANAGER="$2";  shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --port)        API_PORT="$2";    shift 2 ;;
    --dry-run)     DRY_RUN=true;     shift ;;
    --keep-backup) KEEP_BACKUP=true; shift ;;
    --help|-h)
      cat <<HELP
Usage: migrate-pkg-manager.sh --to <brew|macports> [OPTIONS]

必須:
  --to M             移行先のパッケージマネージャー (brew / macports)

OPTIONS:
  --dry-run          実行内容を表示するだけで、何も変更しない
  --keep-backup      成功後もバックアップを残す
                     (既定でも残す。このオプションを付けると削除を勧めない)
  --install-dir DIR  インストール先 (default: $INSTALL_DIR)
  --port PORT        ヘルスチェックのポート (default: .env の TTS_PORT または 8000)
  --help / -h        このヘルプを表示

移行元のパッケージマネージャー本体と、そのパッケージ (python / ffmpeg) は
アンインストールしません。
HELP
      exit 0 ;;
    *) log_error "不明なオプション: $1  (--help で使い方を確認)"; exit 1 ;;
  esac
done

if [[ "$(uname)" != "Darwin" ]]; then
  log_error "このスクリプトは macOS 専用です"; exit 1
fi

if [[ -z "$TO_MANAGER" ]]; then
  log_error "--to <brew|macports> を指定してください  (--help で使い方を確認)"
  exit 1
fi
TO_MANAGER="$(echo "$TO_MANAGER" | tr '[:upper:]' '[:lower:]')"

# ──────────────────────────────────────────────────────────────────
# 共通ライブラリ
# ──────────────────────────────────────────────────────────────────
PKG_LIB_FALLBACK_DIR="$(dirname "${BASH_SOURCE[0]:-/nonexistent}")"
PKG_LIB_LOADED=false
for pkg_lib_candidate in \
  "$PKG_LIB_FALLBACK_DIR/lib/pkg.sh" \
  "$INSTALL_DIR/scripts/lib/pkg.sh"; do
  if [[ -f "$pkg_lib_candidate" ]]; then
    # shellcheck source=lib/pkg.sh
    source "$pkg_lib_candidate"
    PKG_LIB_LOADED=true
    break
  fi
done
if [[ "$PKG_LIB_LOADED" != "true" ]]; then
  log_error "共通ライブラリが見つかりません: scripts/lib/pkg.sh"
  exit 1
fi

if ! pkg_valid "$TO_MANAGER"; then
  log_error "--to に指定できるのは brew か macports です: $TO_MANAGER"
  exit 1
fi

pkg_detect

# ──────────────────────────────────────────────────────────────────
# パス類
# ──────────────────────────────────────────────────────────────────
ENV_FILE="$INSTALL_DIR/.env"
VENV_DIR="$INSTALL_DIR/.venv"
RECORD_FILE="$(pkg_record_file "$INSTALL_DIR")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$INSTALL_DIR/backup/$TIMESTAMP"
VENV_BAK="$INSTALL_DIR/.venv.bak-$TIMESTAMP"

# ロールバック用の進捗フラグ
SERVICE_STOPPED=false
VENV_MOVED=false
NEW_VENV_CREATED=false
ENV_MODIFIED=false
RECORD_MODIFIED=false

# ──────────────────────────────────────────────────────────────────
# ヘルパー
# ──────────────────────────────────────────────────────────────────

# dry-run なら表示だけ、そうでなければ実行する
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [dry-run] $*"
    return 0
  fi
  "$@"
}

# .env から TTS_PORT を読む (無ければ 8000)
detect_port() {
  local value=""
  if [[ -n "$API_PORT" ]]; then
    echo "$API_PORT"; return 0
  fi
  if [[ -f "$ENV_FILE" ]]; then
    value="$(grep -E '^[[:space:]]*TTS_PORT=' "$ENV_FILE" 2>/dev/null | tail -1 || true)"
    value="${value#*=}"
    value="$(echo "$value" | tr -d '[:space:]')"
  fi
  if [[ -n "$value" ]]; then echo "$value"; else echo "8000"; fi
}

# .env から TTS_FFMPEG_PATH を読む
read_env_ffmpeg() {
  local value=""
  if [[ -f "$ENV_FILE" ]]; then
    value="$(grep -E '^[[:space:]]*TTS_FFMPEG_PATH=' "$ENV_FILE" 2>/dev/null | tail -1 || true)"
    value="${value#*=}"
    value="$(echo "$value" | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//')"
  fi
  echo "$value"
}

# 指定パスが、そのマネージャーの配下かどうか
is_under_manager() {
  local mgr="$1" path="$2" prefix
  case "$mgr" in
    brew)
      # brew が既に消えている場合に備えて、既定の prefix も見る
      for prefix in "$(pkg_prefix brew 2>/dev/null || true)" /usr/local /opt/homebrew; do
        [[ -n "$prefix" ]] || continue
        case "$path" in "$prefix"/*) return 0 ;; esac
      done
      ;;
    macports)
      for prefix in "$(pkg_prefix macports 2>/dev/null || true)" /opt/local; do
        [[ -n "$prefix" ]] || continue
        case "$path" in "$prefix"/*) return 0 ;; esac
      done
      ;;
  esac
  return 1
}

# ヘルスチェック (最大 30 秒)
wait_health() {
  local port="$1"
  for _ in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${port}/api/v1/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# サービスの起動 (bootstrap 済みなら kickstart)
start_service() {
  if sudo launchctl print "system/${TTS_DAEMON_LABEL}" >/dev/null 2>&1; then
    sudo launchctl kickstart -k "system/${TTS_DAEMON_LABEL}" >/dev/null 2>&1 || return 1
  else
    sudo launchctl bootstrap system "$PLIST_PATH" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# 失敗時の自動ロールバック
rollback() {
  log_step "ロールバック"
  log_warn "移行に失敗したため、元の状態に戻します"

  # 作りかけの新しい .venv を消す
  if [[ "$NEW_VENV_CREATED" == "true" ]] || [[ "$VENV_MOVED" == "true" && -d "$VENV_DIR" ]]; then
    rm -rf "$VENV_DIR" || log_error "削除に失敗: $VENV_DIR"
    log_ok "新しい .venv を削除しました"
  fi

  # 退避した .venv を戻す
  if [[ "$VENV_MOVED" == "true" ]] && [[ -d "$VENV_BAK" ]]; then
    if mv "$VENV_BAK" "$VENV_DIR"; then
      log_ok "元の .venv を戻しました: $VENV_DIR"
    else
      log_error "元の .venv を戻せませんでした: $VENV_BAK → $VENV_DIR"
    fi
  fi

  # .env を戻す
  if [[ "$ENV_MODIFIED" == "true" ]] && [[ -f "$BACKUP_DIR/.env" ]]; then
    if cat "$BACKUP_DIR/.env" > "$ENV_FILE"; then
      log_ok "元の .env を戻しました"
    else
      log_error "元の .env を戻せませんでした: $BACKUP_DIR/.env"
    fi
  fi

  # .pkg-manager を戻す
  if [[ "$RECORD_MODIFIED" == "true" ]]; then
    if [[ -f "$BACKUP_DIR/.pkg-manager" ]]; then
      if cat "$BACKUP_DIR/.pkg-manager" > "$RECORD_FILE"; then
        log_ok "元の .pkg-manager を戻しました"
      else
        log_error "元の .pkg-manager を戻せませんでした"
      fi
    else
      rm -f "$RECORD_FILE"
      log_ok ".pkg-manager を削除しました (元は未記録)"
    fi
  fi

  # サーバーを再起動する
  if [[ "$SERVICE_STOPPED" == "true" ]]; then
    if start_service; then
      log_ok "サーバーを起動しました"
      if wait_health "$(detect_port)"; then
        log_ok "ヘルスチェック OK — 元のパッケージマネージャーで動作しています"
      else
        log_error "ヘルスチェックに応答しません。ログを確認してください:"
        log_error "  tail -50 $LOG_DIR/stderr.log"
      fi
    else
      log_error "サーバーの起動に失敗しました。手動で確認してください:"
      log_error "  sudo launchctl bootstrap system $PLIST_PATH"
    fi
  fi

  echo ""
  log_error "ロールバックしました。バックアップ: $BACKUP_DIR"
  log_error "ログ: $LOG_DIR/stderr.log, $LOG_DIR/stdout.log"
}

fail() {
  log_error "$*"
  rollback
  exit 1
}

# ──────────────────────────────────────────────────────────────────
# 移行元の判定
# ──────────────────────────────────────────────────────────────────
FROM_MANAGER="$(pkg_read_record "$INSTALL_DIR" 2>/dev/null || true)"
if [[ -z "$FROM_MANAGER" ]]; then
  case "$TO_MANAGER" in
    brew)     FROM_MANAGER="macports" ;;
    macports) FROM_MANAGER="brew" ;;
  esac
  log_warn "記録が見つかりません: $RECORD_FILE"
  log_warn "  移行元を $(pkg_label "$FROM_MANAGER") とみなして続けます"
fi

echo ""
echo -e "${BOLD}=== パッケージマネージャーの移行 ===${RESET}"
echo "  インストール先 : $INSTALL_DIR"
echo "  移行元         : $(pkg_label "$FROM_MANAGER")"
echo "  移行先         : $(pkg_label "$TO_MANAGER")"
[[ "$DRY_RUN" == "true" ]] && echo -e "  モード         : ${BOLD}dry-run (何も変更しません)${RESET}"
echo ""

if [[ "$FROM_MANAGER" == "$TO_MANAGER" ]]; then
  log_error "既に $(pkg_label "$TO_MANAGER") を使っています。移行するものがありません"
  log_error "  .venv を作り直したい場合: bash $INSTALL_DIR/scripts/install.sh"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────
log_step "1. 事前チェック"
# ──────────────────────────────────────────────────────────────────
# ここでは何も変更しない。問題があれば、この時点で止める。

if [[ ! -d "$INSTALL_DIR" ]]; then
  log_error "インストールディレクトリが見つかりません: $INSTALL_DIR"
  log_error "  先に install.sh を実行してください"
  exit 1
fi
log_ok "インストール先: $INSTALL_DIR"

if [[ ! -f "$INSTALL_DIR/requirements.txt" ]]; then
  log_error "requirements.txt が見つかりません: $INSTALL_DIR/requirements.txt"
  exit 1
fi

if ! pkg_have "$TO_MANAGER"; then
  log_error "$(pkg_label "$TO_MANAGER") が見つかりません。先にインストールしてください:"
  pkg_install_hint "$TO_MANAGER" >&2
  log_error "  (この時点では何も変更していません)"
  exit 1
fi
log_ok "$(pkg_label "$TO_MANAGER"): $(pkg_manager_bin "$TO_MANAGER")"

if [[ ! -f "$PLIST_PATH" ]]; then
  log_warn "LaunchDaemon plist が見つかりません: $PLIST_PATH"
  log_warn "  サービスの停止・起動はスキップします"
fi

API_PORT="$(detect_port)"
log_ok "ヘルスチェック先: http://127.0.0.1:${API_PORT}/api/v1/health"

# ──────────────────────────────────────────────────────────────────
log_step "2. 移行先の Python を用意"
# ──────────────────────────────────────────────────────────────────
NEW_PYTHON="$(pkg_python_path "$TO_MANAGER" 2>/dev/null || true)"
if [[ -z "$NEW_PYTHON" ]]; then
  log_warn "$(pkg_label "$TO_MANAGER") 配下に Python 3.11+ がありません。インストールします..."
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [dry-run] $(pkg_label "$TO_MANAGER") で $(pkg_package_name "$TO_MANAGER" python) をインストール"
    NEW_PYTHON="$(pkg_prefix "$TO_MANAGER")/bin/python3.12"
  else
    pkg_install "$TO_MANAGER" python || {
      log_error "Python のインストールに失敗しました (この時点では何も変更していません)"
      exit 1
    }
    NEW_PYTHON="$(pkg_python_path "$TO_MANAGER" 2>/dev/null || true)"
    if [[ -z "$NEW_PYTHON" ]]; then
      log_error "Python のインストール後も見つかりません (この時点では何も変更していません)"
      exit 1
    fi
  fi
fi
log_ok "移行先の Python: $NEW_PYTHON"

NEW_FFMPEG="$(pkg_ffmpeg_path "$TO_MANAGER" 2>/dev/null || true)"
if [[ -n "$NEW_FFMPEG" ]]; then
  log_ok "移行先の ffmpeg: $NEW_FFMPEG"
else
  log_warn "$(pkg_label "$TO_MANAGER") 配下に ffmpeg がありません (MP3 出力は使えなくなります)"
fi

# ──────────────────────────────────────────────────────────────────
log_step "3. バックアップ"
# ──────────────────────────────────────────────────────────────────
run mkdir -p "$BACKUP_DIR"
for item in "$ENV_FILE" "$PLIST_PATH" "$RECORD_FILE"; do
  if [[ -f "$item" ]]; then
    run cp -p "$item" "$BACKUP_DIR/" || fail "バックアップに失敗しました: $item"
    log_ok "バックアップ: $item"
  else
    log_warn "存在しないためスキップ: $item"
  fi
done
log_info "バックアップ先: $BACKUP_DIR"

# ここから先は、失敗したら rollback する
# ──────────────────────────────────────────────────────────────────
log_step "4. サービスの停止"
# ──────────────────────────────────────────────────────────────────
if [[ -f "$PLIST_PATH" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [dry-run] sudo launchctl bootout system $PLIST_PATH"
  else
    sudo launchctl bootout system "$PLIST_PATH" 2>/dev/null || true
    SERVICE_STOPPED=true
    log_ok "停止しました: $TTS_DAEMON_LABEL"
  fi
else
  log_warn "plist が無いためスキップ"
fi

# ──────────────────────────────────────────────────────────────────
log_step "5. 仮想環境の退避"
# ──────────────────────────────────────────────────────────────────
if [[ -d "$VENV_DIR" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "    [dry-run] mv $VENV_DIR $VENV_BAK"
  else
    mv "$VENV_DIR" "$VENV_BAK" || fail "仮想環境の退避に失敗しました: $VENV_DIR"
    VENV_MOVED=true
    log_ok "退避しました (削除はしていません): $VENV_BAK"
  fi
else
  log_warn "仮想環境がありません: $VENV_DIR"
fi

# ──────────────────────────────────────────────────────────────────
log_step "6. 仮想環境の再作成"
# ──────────────────────────────────────────────────────────────────
# plist の ProgramArguments が指す場所なので、必ず同じパスに作り直す。
if [[ "$DRY_RUN" == "true" ]]; then
  echo "    [dry-run] $NEW_PYTHON -m venv $VENV_DIR"
  echo "    [dry-run] $VENV_DIR/bin/pip install -r $INSTALL_DIR/requirements.txt"
else
  "$NEW_PYTHON" -m venv "$VENV_DIR" </dev/null \
    || fail "仮想環境の作成に失敗しました: $NEW_PYTHON -m venv $VENV_DIR"
  NEW_VENV_CREATED=true
  log_ok "作成しました: $VENV_DIR ($("$VENV_DIR/bin/python" --version 2>&1))"

  "$VENV_DIR/bin/pip" install --quiet --upgrade pip </dev/null \
    || fail "pip の更新に失敗しました"
  "$VENV_DIR/bin/pip" install --quiet -r "$INSTALL_DIR/requirements.txt" </dev/null \
    || fail "依存パッケージのインストールに失敗しました"
  log_ok "依存パッケージをインストールしました"
fi

# ──────────────────────────────────────────────────────────────────
log_step "7. .env の ffmpeg パス更新"
# ──────────────────────────────────────────────────────────────────
# 移行元マネージャー配下の絶対パス、または 'ffmpeg' の場合だけ書き換える。
# ユーザーが独自に設定した値は変更しない。
if [[ ! -f "$ENV_FILE" ]]; then
  log_warn ".env がないためスキップ: $ENV_FILE"
else
  CURRENT_FFMPEG="$(read_env_ffmpeg)"
  TARGET_FFMPEG=""
  if [[ -n "$NEW_FFMPEG" ]]; then
    TARGET_FFMPEG="$NEW_FFMPEG"
  else
    TARGET_FFMPEG="ffmpeg"
  fi

  SHOULD_UPDATE=false
  if [[ -z "$CURRENT_FFMPEG" ]]; then
    log_warn "TTS_FFMPEG_PATH の行がありません (変更しません)"
  elif [[ "$CURRENT_FFMPEG" == "ffmpeg" ]]; then
    SHOULD_UPDATE=true
  elif is_under_manager "$FROM_MANAGER" "$CURRENT_FFMPEG"; then
    SHOULD_UPDATE=true
  else
    log_info "TTS_FFMPEG_PATH は独自の値のため変更しません: $CURRENT_FFMPEG"
  fi

  if [[ "$SHOULD_UPDATE" == "true" ]] && [[ "$CURRENT_FFMPEG" == "$TARGET_FFMPEG" ]]; then
    SHOULD_UPDATE=false
    log_info "TTS_FFMPEG_PATH は既に $TARGET_FFMPEG です (変更不要)"
  fi

  if [[ "$SHOULD_UPDATE" == "true" ]]; then
    log_info "TTS_FFMPEG_PATH を変更します"
    echo "    変更前: $CURRENT_FFMPEG"
    echo "    変更後: $TARGET_FFMPEG"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "    [dry-run] $ENV_FILE を書き換え"
    else
      ENV_TMP="$(mktemp)" || fail "一時ファイルを作れませんでした"
      sed "s#^[[:space:]]*TTS_FFMPEG_PATH=.*#TTS_FFMPEG_PATH=${TARGET_FFMPEG}#" \
        "$ENV_FILE" > "$ENV_TMP" || { rm -f "$ENV_TMP"; fail ".env の書き換えに失敗しました"; }
      # 所有者・パーミッションを保つため、cp ではなく中身を上書きする
      cat "$ENV_TMP" > "$ENV_FILE" || { rm -f "$ENV_TMP"; fail ".env の書き込みに失敗しました"; }
      rm -f "$ENV_TMP"
      ENV_MODIFIED=true
      log_ok ".env を更新しました"
    fi
  fi

  if [[ "$TARGET_FFMPEG" == "ffmpeg" ]] && [[ "$SHOULD_UPDATE" == "true" ]]; then
    log_warn "移行先に ffmpeg がないため MP3 出力は使えません"
    case "$TO_MANAGER" in
      brew)     log_warn "  導入する場合: brew install ffmpeg" ;;
      macports) log_warn "  導入する場合: sudo port install ffmpeg" ;;
    esac
  fi
fi

# ──────────────────────────────────────────────────────────────────
log_step "8. パッケージマネージャーの記録を更新"
# ──────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo "    [dry-run] echo $TO_MANAGER > $RECORD_FILE"
else
  pkg_write_record "$INSTALL_DIR" "$TO_MANAGER" || fail "記録の更新に失敗しました: $RECORD_FILE"
  RECORD_MODIFIED=true
  log_ok "$RECORD_FILE → $TO_MANAGER"
fi

# ──────────────────────────────────────────────────────────────────
log_step "9. 起動と動作確認"
# ──────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo "    [dry-run] sudo launchctl bootstrap system $PLIST_PATH"
  echo "    [dry-run] curl http://127.0.0.1:${API_PORT}/api/v1/health (最大30秒リトライ)"
elif [[ ! -f "$PLIST_PATH" ]]; then
  log_warn "plist が無いため起動確認はスキップします"
  log_warn "  起動するには install.sh を実行してください"
else
  start_service || fail "サービスの起動に失敗しました"
  SERVICE_STOPPED=true
  log_info "ヘルスチェック中 (最大30秒)..."
  if wait_health "$API_PORT"; then
    log_ok "OK — TTS API が応答しています"
    curl -s "http://127.0.0.1:${API_PORT}/api/v1/health" 2>/dev/null \
      | "$VENV_DIR/bin/python" -m json.tool 2>/dev/null || true
  else
    fail "ヘルスチェックに応答しません (30秒待機)"
  fi
fi

# ──────────────────────────────────────────────────────────────────
# 完了
# ──────────────────────────────────────────────────────────────────
echo ""
if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "${BOLD}${GREEN}=== dry-run 完了 (何も変更していません) ===${RESET}"
  echo ""
  echo "  実際に移行するには --dry-run を外して実行してください:"
  echo "    bash $0 --to $TO_MANAGER"
  exit 0
fi

echo -e "${BOLD}${GREEN}=== 移行完了! ===${RESET}"
echo ""
echo "  パッケージマネージャー : $(pkg_label "$FROM_MANAGER") → $(pkg_label "$TO_MANAGER")"
echo "  Python                 : $NEW_PYTHON"
echo "  記録                   : $RECORD_FILE"
echo ""
echo "バックアップ (.env / plist / .pkg-manager):"
echo "  $BACKUP_DIR"
echo "退避した仮想環境:"
echo "  $VENV_BAK"
echo ""
if [[ "$KEEP_BACKUP" == "true" ]]; then
  echo "  --keep-backup が指定されたため、そのまま残します"
else
  echo "  問題がなければ、不要になった時点で削除できます:"
  echo "    rm -rf $VENV_BAK"
  echo "    rm -rf $BACKUP_DIR"
fi
echo ""
log_warn "$(pkg_label "$FROM_MANAGER") 本体と、そのパッケージ (python / ffmpeg) は削除していません"
case "$FROM_MANAGER" in
  brew)
    echo "  削除する場合は、先に tts-api が巻き込まれないか確認してください:"
    echo "    既定のインストール先 /usr/local/opt と /usr/local/var は"
    echo "    Intel Mac の Homebrew と同じ場所にあります。"
    echo "    アンインストーラーのドライラン (--dry-run) で確認し、"
    echo "    $ENV_FILE をバックアップしてから実行してください。"
    ;;
  macports)
    echo "  削除する場合: sudo port uninstall python312 ffmpeg"
    ;;
esac
