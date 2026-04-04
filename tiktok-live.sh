#!/bin/sh
# tiktok-live — TikTok Live event stream in your terminal
# Usage: tiktok-live <username>
set +e

_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$_SCRIPT_DIR/lib/piratetok.sh"

# --- event handlers ---
on_chat()    { printf '\033[36m[chat]\033[0m %s: %s\n' "$1" "$2"; }
on_gift()    { printf '\033[33m[gift]\033[0m %s sent %s x%s (%s diamonds)\n' "$1" "$2" "$3" "$4"; }
on_like()    { printf '\033[35m[like]\033[0m %s (%s total)\n' "$1" "$2"; }
on_join()    { printf '\033[32m[join]\033[0m %s\n' "$1"; }
on_follow()  { printf '\033[32m[follow]\033[0m %s\n' "$1"; }
on_share()   { printf '\033[34m[share]\033[0m %s\n' "$1"; }
on_viewers() { :; }
on_ended()   { echo "[ended]"; }
on_status()  { echo "[*] $*"; }
on_error()   { echo "error: $*" >&2; exit 1; }

[ -z "$1" ] && { echo "usage: $0 <username>" >&2; exit 1; }

pt_connect "$1"
echo "[*] disconnected"
