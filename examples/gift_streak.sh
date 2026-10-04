#!/bin/sh
# gift_streak.sh USER - per-event gift deltas (TikTok only sends running totals)
. "${PT_LIB_DIR:-$(dirname "$0")/../lib}/piratetok.sh"
on_gift() {
    pt_gift_streak
    printf '%s sent %s: +%s (streak total %s, %s diamonds)%s\n' "$1" "$2" "$PT_STREAK_EVENT_COUNT" \
        "$PT_STREAK_TOTAL_COUNT" "$PT_STREAK_TOTAL_DIAMONDS" "$( [ "$PT_STREAK_FINAL" = 1 ] && echo ' [final]')"
}
trap 'pt_disconnect' INT
pt_connect "$1"
