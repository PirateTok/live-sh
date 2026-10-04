# pt_helpers.sh - gift/like/badge helpers over the current event (PT_EV_FIELDS). Sourced by piratetok.sh.

: "${PT_STREAK_STALE_SEC:=60}"

# --- gift helpers (same rules as live-rs WebcastGiftMessage) ---
pt_gift_is_combo() { [ "$(pt_field gift_details.gift_type)" = 1 ]; }
pt_gift_is_streak_over() { ! pt_gift_is_combo || [ "$(pt_field repeat_end)" = 1 ]; }
pt_gift_diamond_total() {
    pt_get gift_details.diamond_count repeat_count
    _gd_rep=${_g2:-0}; [ "$_gd_rep" -lt 1 ] && _gd_rep=1
    echo $(( ${_g1:-0} * _gd_rep ))
}

# pt_gift_streak -> PT_STREAK_ID, PT_STREAK_ACTIVE, PT_STREAK_FINAL (0/1), PT_STREAK_EVENT_COUNT (delta),
#   PT_STREAK_TOTAL_COUNT, PT_STREAK_EVENT_DIAMONDS, PT_STREAK_TOTAL_DIAMONDS  (GiftStreakTracker)
pt_gift_streak() {
    pt_get group_id repeat_count gift_details.diamond_count
    PT_STREAK_ID=${_g1:-0}; _gs_rep=${_g2:-0}; _gs_per=${_g3:-0}
    if pt_gift_is_streak_over; then PT_STREAK_FINAL=1; else PT_STREAK_FINAL=0; fi
    if ! pt_gift_is_combo; then
        PT_STREAK_ACTIVE=0; PT_STREAK_EVENT_COUNT=1; PT_STREAK_TOTAL_COUNT=1
        PT_STREAK_EVENT_DIAMONDS=$_gs_per; PT_STREAK_TOTAL_DIAMONDS=$_gs_per
        return 0
    fi
    _gs_now=$(date +%s)
    eval "_gs_prev=\${_PT_GS_$PT_STREAK_ID:-}"
    _gs_prev_count=0
    if [ -n "$_gs_prev" ] && [ $((_gs_now - ${_gs_prev#*:})) -lt "$PT_STREAK_STALE_SEC" ]; then _gs_prev_count=${_gs_prev%%:*}; fi
    PT_STREAK_EVENT_COUNT=$((_gs_rep - _gs_prev_count)); [ "$PT_STREAK_EVENT_COUNT" -lt 0 ] && PT_STREAK_EVENT_COUNT=0
    if [ "$PT_STREAK_FINAL" = 1 ]; then eval "unset _PT_GS_$PT_STREAK_ID"; else eval "_PT_GS_$PT_STREAK_ID=$_gs_rep:$_gs_now"; fi
    _gs_mult=$_gs_rep; [ "$_gs_mult" -lt 1 ] && _gs_mult=1
    PT_STREAK_ACTIVE=$((1 - PT_STREAK_FINAL)); PT_STREAK_TOTAL_COUNT=$_gs_rep
    PT_STREAK_EVENT_DIAMONDS=$((_gs_per * PT_STREAK_EVENT_COUNT)); PT_STREAK_TOTAL_DIAMONDS=$((_gs_per * _gs_mult))
}

# pt_like_accumulate -> PT_LIKE_EVENT, PT_LIKE_TOTAL (monotonic max), PT_LIKE_ACCUMULATED, PT_LIKE_BACKWARDS (0/1)
pt_like_accumulate() {
    pt_get count total
    PT_LIKE_EVENT=${_g1:-0}; _la_total=${_g2:-0}
    _PT_LIKE_ACC=$(( ${_PT_LIKE_ACC:-0} + PT_LIKE_EVENT ))
    if [ "$_la_total" -lt "${_PT_LIKE_MAX:-0}" ]; then PT_LIKE_BACKWARDS=1; else PT_LIKE_BACKWARDS=0; fi
    [ "$_la_total" -gt "${_PT_LIKE_MAX:-0}" ] && _PT_LIKE_MAX=$_la_total
    PT_LIKE_TOTAL=${_PT_LIKE_MAX:-0}; PT_LIKE_ACCUMULATED=$_PT_LIKE_ACC
}

pt_like_reset() { _PT_LIKE_ACC=0; _PT_LIKE_MAX=0; }

# --- enriched user (badge scenes: 1 admin, 6 rank list, 8 user grade, 10 fans) ---
# pt_user_badge_level SCENE [PREFIX] -> log_extra.level of the first badge with that scene (empty if none)
pt_user_badge_level() {
    printf '%s' "$PT_EV_FIELDS" | LC_ALL=C awk -F "$PT_TAB" -v pre="${2:-user}.badge_list." -v scene="$1" '
        index($1, pre) == 1 { rest = substr($1, length(pre) + 1); i = substr(rest, 1, index(rest, ".") - 1); k = substr(rest, length(i) + 2); V[i, k] = $2; if (i + 1 > n) n = i + 1 }
        END { for (i = 0; i < n; i++) if (V[i, "badge_scene"] == scene) { print V[i, "log_extra.level"]; exit } }'
}
pt_user_has_badge() { printf '%s' "$PT_EV_FIELDS" | grep -q "^${2:-user}\.badge_list\.[0-9]*\.badge_scene$PT_TAB$1\$"; }
pt_gifter_level() { pt_user_badge_level 8 "$1"; }
pt_member_level() { pt_user_badge_level 10 "$1"; }
pt_is_moderator() { pt_user_has_badge 1 "$1"; }
pt_is_top_gifter() { pt_user_has_badge 6 "$1"; }
