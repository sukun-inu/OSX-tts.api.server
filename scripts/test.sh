#!/usr/bin/env bash
# update.sh --reset に統合されました。後方互換のため残しています。
exec "$(dirname "$0")/update.sh" --reset "$@"
