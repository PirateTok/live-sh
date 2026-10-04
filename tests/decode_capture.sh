#!/bin/sh
# decode_capture.sh CAPTURE.bin -> pt_proto.awk response-mode output for every "msg" frame
# (A/E/F/Z lines, see lib/pt_proto.awk). Used by tests/replay.sh.
set -e
LC_ALL=C
export LC_ALL
LIB=$(cd "$(dirname "$0")/../lib" && pwd)
TAB=$(printf '\t')
od -An -tx1 -v "$1" | tr -d ' \n' | awk -f "$LIB/pt_frames.awk" |
    awk -v schema="$LIB/piratetok.proto" -v mode=frame -f "$LIB/pt_proto.awk" |
    while IFS="$TAB" read -r ptype logid payload; do
        [ "$ptype" = msg ] || continue
        case $payload in
            1f8b*) payload=$(printf '%s\n' "$payload" | awk -f "$LIB/pt_unhex.awk" | gzip -dc | od -An -tx1 -v | tr -d ' \n') ;;
        esac
        printf '%s\n' "$payload"
    done |
    awk -v schema="$LIB/piratetok.proto" -v events="$LIB/pt_events.tsv" -v mode=response -f "$LIB/pt_proto.awk"
