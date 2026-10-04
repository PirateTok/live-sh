#!/bin/sh
# audience.sh USER [COOKIES] - full named roster (login-gated) + live top-viewers box (no cookies)
. "${PT_LIB_DIR:-$(dirname "$0")/../lib}/piratetok.sh"
pt_resolve_room "$1"
[ "$PT_ONLINE" = LIVE ] || { echo "$PT_ERROR" >&2; exit 1; }
on_audience_viewer() { printf '  #%-3s @%s (%s) score=%s followers=%s\n' "$1" "$4" "$5" "$2" "$6"; }
if pt_fetch_room_audience "$PT_ROOM_ID" "$PT_ANCHOR_ID" "$2"; then
    echo "=== roster: $PT_AUD_TOTAL in room ($PT_AUD_ANON anonymous) ==="
else
    echo "[roster] $PT_ERROR"
fi
on_top_viewer() { printf '[top] #%s %s (@%s) score=%s\n' "$1" "$3" "$4" "$2"; }
trap 'pt_disconnect' INT
pt_connect "$1"
