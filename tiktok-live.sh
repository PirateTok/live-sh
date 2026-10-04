#!/bin/sh
# tiktok-live - TikTok Live event stream in your terminal
# Usage: tiktok-live <username>     (env: PT_PROXY, PT_COOKIES, PT_LANGUAGE, PT_REGION, PT_MAX_RETRIES, ...)

_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
for _p in "$PT_LIB_DIR" "$_SCRIPT_DIR/lib" "$_SCRIPT_DIR/../lib/piratetok" "$HOME/.local/lib/piratetok" "/usr/local/lib/piratetok"; do
    [ -n "$_p" ] && [ -f "$_p/piratetok.sh" ] && { PT_LIB_DIR=$_p; break; }
done
[ -f "$PT_LIB_DIR/piratetok.sh" ] || { echo "error: piratetok.sh not found (set PT_LIB_DIR)" >&2; exit 1; }
. "$PT_LIB_DIR/piratetok.sh"

on_chat()         { printf '\033[36m[chat]\033[0m %s: %s\n' "$1" "$2"; }
on_gift()         { pt_gift_streak; [ "$PT_STREAK_FINAL" = 1 ] && printf '\033[33m[gift]\033[0m %s sent %s x%s (%s diamonds)\n' "$1" "$2" "$PT_STREAK_TOTAL_COUNT" "$PT_STREAK_TOTAL_DIAMONDS"; }
on_like()         { printf '\033[35m[like]\033[0m %s (%s total)\n' "$1" "$2"; }
on_join()         { printf '\033[32m[join]\033[0m %s\n' "$1"; }
on_follow()       { printf '\033[32m[follow]\033[0m %s\n' "$1"; }
on_share()        { printf '\033[34m[share]\033[0m %s\n' "$1"; }
on_ended()        { echo "[ended]"; }
on_reconnecting() { echo "[*] reconnecting (attempt $1/$2) in ${3}s"; }
on_status()       { echo "[*] $*"; }
on_error()        { echo "error: $*" >&2; }

[ -z "$1" ] && { echo "usage: $0 <username>" >&2; exit 1; }
trap 'pt_disconnect' INT
pt_connect "$1" || exit 1
echo "[*] disconnected"
