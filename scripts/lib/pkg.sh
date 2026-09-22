#!/usr/bin/env bash
# ================================================================
# OSX TTS API — パッケージマネージャー共通ライブラリ
#
# Homebrew と MacPorts のどちらでもインストール・更新・運用できるように
# するための共通処理。各スクリプトから source して使う。
#
#   source "$(dirname "$0")/lib/pkg.sh"
#   pkg_detect
#   pkg_resolve_manager "$CLI_PKG_MANAGER" "$INSTALL_DIR" || exit 1
#   echo "$PKG_MANAGER"   # brew | macports
#
# 【制約】bash 3.2 で動くこと。
#   macOS 標準の /bin/bash は 3.2 系で、Homebrew を消した環境ではこれが使われる。
#   連想配列 (declare -A) や ${var,,} など bash 4 以降の機能は使わない。
# ================================================================
# shellcheck shell=bash
# PKG_MANAGER / PKG_MANAGER_SOURCE / PKG_BREW_BIN / PKG_PORT_BIN は
# source 元のスクリプトが参照するため、このファイル内では未使用に見える。
# shellcheck disable=SC2034

# 二重 source の防止
if [ -n "${TTS_PKG_SH_LOADED:-}" ]; then
  # source ではなく直接実行された場合、return は失敗するので握りつぶす
  # shellcheck disable=SC2317
  return 0 2>/dev/null || true
fi
TTS_PKG_SH_LOADED=1

# ──────────────────────────────────────────────────────────────────
# ログ関数のフォールバック
#   source 元が同名の関数を定義済みならそちらを使う。
# ──────────────────────────────────────────────────────────────────
if ! command -v log_info >/dev/null 2>&1; then
  log_info() { echo "[+] $*"; }
fi
if ! command -v log_warn >/dev/null 2>&1; then
  log_warn() { echo "[!] $*" >&2; }
fi
if ! command -v log_error >/dev/null 2>&1; then
  log_error() { echo "[x] $*" >&2; }
fi

# ライブラリ内部のメッセージは常に stderr へ。
# 値を stdout に返す関数と混ざらないようにするため。
_pkg_msg() { echo "$*" >&2; }

_pkg_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

# ──────────────────────────────────────────────────────────────────
# 検出
#   PATH が通っていない場合 (curl | bash 実行時など) でも見つけられるよう、
#   実体パスを直接確認する。
# ──────────────────────────────────────────────────────────────────
PKG_BREW_BIN=""
PKG_PORT_BIN=""
PKG_MANAGER=""
PKG_MANAGER_SOURCE=""

pkg_detect() {
  PKG_BREW_BIN=""
  PKG_PORT_BIN=""

  local candidate
  for candidate in /usr/local/bin/brew /opt/homebrew/bin/brew; do
    if [ -x "$candidate" ]; then
      PKG_BREW_BIN="$candidate"
      break
    fi
  done
  if [ -z "$PKG_BREW_BIN" ] && command -v brew >/dev/null 2>&1; then
    PKG_BREW_BIN="$(command -v brew)"
  fi

  if [ -x /opt/local/bin/port ]; then
    PKG_PORT_BIN=/opt/local/bin/port
  elif command -v port >/dev/null 2>&1; then
    PKG_PORT_BIN="$(command -v port)"
  fi
}

# pkg_have <brew|macports>  … 存在すれば 0
pkg_have() {
  case "$1" in
    brew)     [ -n "$PKG_BREW_BIN" ] ;;
    macports) [ -n "$PKG_PORT_BIN" ] ;;
    *)        return 1 ;;
  esac
}

# pkg_manager_bin <brew|macports>  … マネージャー本体の絶対パス
pkg_manager_bin() {
  case "$1" in
    brew)     [ -n "$PKG_BREW_BIN" ] && echo "$PKG_BREW_BIN" ;;
    macports) [ -n "$PKG_PORT_BIN" ] && echo "$PKG_PORT_BIN" ;;
    *)        return 1 ;;
  esac
}

# pkg_label <brew|macports>  … 表示用の名前
pkg_label() {
  case "$1" in
    brew)     echo "Homebrew" ;;
    macports) echo "MacPorts" ;;
    *)        echo "$1" ;;
  esac
}

# pkg_valid <name>  … brew / macports のいずれかなら 0
pkg_valid() {
  case "$1" in
    brew|macports) return 0 ;;
    *)             return 1 ;;
  esac
}

# pkg_install_hint <brew|macports>  … 導入方法の案内 (stdout)
pkg_install_hint() {
  case "$1" in
    brew)
      # 案内文としてそのまま表示する。展開させないため意図的にシングルクォート
      # shellcheck disable=SC2016
      echo '  Homebrew : /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
      ;;
    macports)
      echo '  MacPorts : https://www.macports.org/install.php から macOS のバージョンに合う pkg を入れる'
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────
# prefix と実行ファイルの絶対パス解決
#   command -v の結果だけには頼らない。両方入っている環境では、
#   選んでいない側の実行ファイルを拾ってしまうため。
# ──────────────────────────────────────────────────────────────────

# pkg_prefix <brew|macports>  … /usr/local, /opt/homebrew, /opt/local など
pkg_prefix() {
  case "$1" in
    brew)
      [ -n "$PKG_BREW_BIN" ] || return 1
      "$PKG_BREW_BIN" --prefix 2>/dev/null \
        || dirname "$(dirname "$PKG_BREW_BIN")"
      ;;
    macports)
      [ -n "$PKG_PORT_BIN" ] || return 1
      dirname "$(dirname "$PKG_PORT_BIN")"
      ;;
    *)
      return 1
      ;;
  esac
}

# pkg_exec_path <brew|macports> <実行ファイル名>  … 絶対パス (無ければ 1)
pkg_exec_path() {
  local mgr="$1" exe="$2" prefix
  prefix="$(pkg_prefix "$mgr" 2>/dev/null || true)"
  [ -n "$prefix" ] || return 1
  if [ -x "$prefix/bin/$exe" ]; then
    echo "$prefix/bin/$exe"
    return 0
  fi
  return 1
}

# pkg_python_path <brew|macports>  … Python 3.11+ の絶対パス (無ければ 1)
#   3.13 → 3.12 → 3.11 の順に、そのマネージャーの配下だけを探す。
pkg_python_path() {
  local mgr="$1" ver path
  for ver in 3.13 3.12 3.11; do
    path="$(pkg_exec_path "$mgr" "python$ver" 2>/dev/null || true)"
    if [ -n "$path" ] \
      && "$path" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' >/dev/null 2>&1; then
      echo "$path"
      return 0
    fi
  done
  return 1
}

# pkg_ffmpeg_path <brew|macports>  … ffmpeg の絶対パス (無ければ 1)
pkg_ffmpeg_path() {
  pkg_exec_path "$1" ffmpeg
}

# ──────────────────────────────────────────────────────────────────
# パッケージ名の対応表
#   論理名 | Homebrew     | MacPorts
#   -------|--------------|-----------
#   python | python@3.12  | python312
#   git    | git          | git
#   ffmpeg | ffmpeg       | ffmpeg
# ──────────────────────────────────────────────────────────────────
pkg_package_name() {
  local mgr="$1" logical="$2"
  case "$mgr:$logical" in
    brew:python)     echo "python@3.12" ;;
    macports:python) echo "python312" ;;
    brew:git)        echo "git" ;;
    macports:git)    echo "git" ;;
    brew:ffmpeg)     echo "ffmpeg" ;;
    macports:ffmpeg) echo "ffmpeg" ;;
    *)
      _pkg_msg "対応表にないパッケージです: $logical ($mgr)"
      return 1
      ;;
  esac
}

# pkg_install <brew|macports> <論理名>
#   brew は sudo なしで実行する (brew は root 実行を拒否するため)。
#   MacPorts は /opt/local への書き込みに root 権限が要るので sudo を付ける。
pkg_install() {
  local mgr="$1" logical="$2" name
  name="$(pkg_package_name "$mgr" "$logical")" || return 1

  case "$mgr" in
    brew)
      [ -n "$PKG_BREW_BIN" ] || { log_error "Homebrew が見つかりません"; return 1; }
      log_info "Homebrew で $name をインストールします..."
      "$PKG_BREW_BIN" install "$name" </dev/null
      ;;
    macports)
      [ -n "$PKG_PORT_BIN" ] || { log_error "MacPorts が見つかりません"; return 1; }
      log_info "MacPorts で $name をインストールします (sudo)..."
      sudo "$PKG_PORT_BIN" install "$name" </dev/null
      ;;
    *)
      log_error "不正なパッケージマネージャー: $mgr"
      return 1
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────
# 選択したマネージャーの記録
#   $INSTALL_DIR/.pkg-manager に "brew" または "macports" の1語で保存する。
#   .env には書かない (アプリの設定項目と混ぜないため)。
# ──────────────────────────────────────────────────────────────────
pkg_record_file() {
  local dir="${1%/}"
  echo "$dir/.pkg-manager"
}

# pkg_read_record <install_dir>  … 記録済みの値 (無効・未記録なら 1)
pkg_read_record() {
  local file value
  file="$(pkg_record_file "$1")"
  [ -f "$file" ] || return 1
  value="$(tr -d '[:space:]' < "$file" | tr '[:upper:]' '[:lower:]')"
  if pkg_valid "$value"; then
    echo "$value"
    return 0
  fi
  return 1
}

# pkg_write_record <install_dir> <brew|macports>
pkg_write_record() {
  local dir="$1" mgr="$2" file
  pkg_valid "$mgr" || { log_error "不正なパッケージマネージャー: $mgr"; return 1; }
  file="$(pkg_record_file "$dir")"
  if ! echo "$mgr" > "$file" 2>/dev/null; then
    echo "$mgr" | sudo tee "$file" >/dev/null
  fi
}

# ──────────────────────────────────────────────────────────────────
# 使うマネージャーの決定
#
#   pkg_resolve_manager <CLI で指定された値 (空可)> <install_dir (空可)>
#
#   優先順位: CLI > 環境変数 TTS_PKG_MANAGER > 記録済みの値 > 自動判定
#   結果はグローバル変数 PKG_MANAGER / PKG_MANAGER_SOURCE に入る。
#   (値を stdout に返さないのは、$(...) で呼ぶと pkg_detect が設定した
#    PKG_BREW_BIN などがサブシェルに閉じ込められてしまうため)
# ──────────────────────────────────────────────────────────────────
pkg_resolve_manager() {
  local cli="${1:-}" install_dir="${2:-}"
  local want="" origin="" recorded="" env_value=""

  pkg_detect

  # --- 1. CLI オプション ---
  if [ -n "$cli" ]; then
    cli="$(_pkg_lower "$cli")"
    if [ "$cli" != "auto" ]; then
      want="$cli"
      origin="--pkg-manager オプション"
    fi
  fi

  # --- 2. 環境変数 ---
  if [ -z "$want" ] && [ -n "${TTS_PKG_MANAGER:-}" ]; then
    env_value="$(_pkg_lower "${TTS_PKG_MANAGER}")"
    if [ "$env_value" != "auto" ]; then
      want="$env_value"
      origin="環境変数 TTS_PKG_MANAGER"
    fi
  fi

  if [ -n "$want" ]; then
    if ! pkg_valid "$want"; then
      log_error "不正なパッケージマネージャー: $want ($origin)"
      log_error "  指定できる値: brew / macports / auto"
      return 1
    fi
    if ! pkg_have "$want"; then
      log_error "$(pkg_label "$want") が指定されましたが ($origin)、見つかりません"
      pkg_install_hint "$want" >&2
      return 1
    fi
    PKG_MANAGER="$want"
    PKG_MANAGER_SOURCE="$origin"
    return 0
  fi

  # --- 3. 記録済みの値 ---
  if [ -n "$install_dir" ]; then
    recorded="$(pkg_read_record "$install_dir" 2>/dev/null || true)"
  fi
  if [ -n "$recorded" ]; then
    if pkg_have "$recorded"; then
      PKG_MANAGER="$recorded"
      PKG_MANAGER_SOURCE="記録 ($(pkg_record_file "$install_dir"))"
      return 0
    fi
    log_error "記録されている $(pkg_label "$recorded") が見つかりません: $(pkg_record_file "$install_dir")"
    log_error "  マネージャーを乗り換える場合は移行スクリプトを使ってください:"
    log_error "    bash $install_dir/scripts/migrate-pkg-manager.sh --to <brew|macports>"
    log_error "  記録を無視して続ける場合は --pkg-manager で明示してください"
    return 1
  fi

  # --- 4. 自動判定 ---
  if pkg_have brew && pkg_have macports; then
    log_error "Homebrew と MacPorts の両方が見つかりました。どちらを使うか指定してください:"
    log_error "    --pkg-manager brew"
    log_error "    --pkg-manager macports"
    log_error "  (環境変数 TTS_PKG_MANAGER でも指定できます)"
    return 1
  fi
  if pkg_have brew; then
    PKG_MANAGER="brew"
    PKG_MANAGER_SOURCE="自動判定"
    return 0
  fi
  if pkg_have macports; then
    PKG_MANAGER="macports"
    PKG_MANAGER_SOURCE="自動判定"
    return 0
  fi

  log_error "Homebrew も MacPorts も見つかりません。どちらかをインストールしてください:"
  pkg_install_hint brew >&2
  pkg_install_hint macports >&2
  return 1
}
