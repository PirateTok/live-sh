#!/bin/sh
# basic_chat.sh USER - connect and print chat; Ctrl+C disconnects cleanly
. "${PT_LIB_DIR:-$(dirname "$0")/../lib}/piratetok.sh"
on_connected() { echo "[connected] room $1"; }
on_chat() { echo "$1: $2"; }
on_reconnecting() { echo "[reconnecting] $1/$2 in ${3}s"; }
on_disconnected() { echo "[disconnected]"; }
trap 'pt_disconnect' INT
pt_connect "$1"
