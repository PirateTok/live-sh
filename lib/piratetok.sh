#!/bin/sh
# piratetok.sh - TikTok Live connector library (POSIX sh + openssl + awk + gzip).
# Source it, define handlers, call pt_connect USERNAME. See README for the full API.
# The companion files (pt_*.sh, pt_*.awk, piratetok.proto, pt_events.tsv) must sit next to
# this file; set PT_LIB_DIR if it can't be found automatically.

_PT_SOURCED=1

# --- locate companion files ---
if [ -z "$PT_LIB_DIR" ]; then
    for _pt_d in "$(dirname "$0")/lib" "$(dirname "$0")/../lib/piratetok" "$(dirname "$0")" \
        "$HOME/.local/lib/piratetok" "/usr/local/lib/piratetok" "/usr/lib/piratetok"; do
        [ -f "$_pt_d/pt_proto.awk" ] && { PT_LIB_DIR=$(cd "$_pt_d" && pwd); break; }
    done
fi
[ -f "$PT_LIB_DIR/pt_proto.awk" ] || { echo "piratetok.sh: companion files not found, set PT_LIB_DIR" >&2; return 1 2>/dev/null || exit 1; }

# --- config (override before calling pt_*) ---
: "${PT_WEB_HOST:=www.tiktok.com}"
: "${PT_WEB_PORT:=443}"
: "${PT_WEBCAST_HOST:=webcast.tiktok.com}"
: "${PT_WEBCAST_PORT:=443}"
: "${PT_CDN:=webcast-ws.tiktok.com}"
: "${PT_WS_PORT:=443}"
: "${PT_HEARTBEAT_SEC:=10}"
: "${PT_STALE_SEC:=60}"
: "${PT_MAX_RETRIES:=5}"
: "${PT_UA:=}"
: "${PT_COOKIES:=}"
: "${PT_PROXY:=}"
: "${PT_CAFILE:=}"
: "${PT_LANGUAGE:=}"
: "${PT_REGION:=}"
: "${PT_COMPRESS:=1}"
: "${PT_TTWID_ATTEMPTS:=8}"
: "${PT_TTWID_DELAY:=0.75}"
: "${PT_HEALTHY_SEC:=30}"
: "${PT_BLOCKED_DELAY:=2}"
: "${PT_MAX_BACKOFF:=30}"
: "${PT_CACHE_DIR:=${TMPDIR:-/tmp}/piratetok-$(id -u)}"
: "${PT_PROFILE_TTL:=300}"

PT_TAB=$(printf '\t')

# --- default event handlers (override these) ---
on_event() { :; }
on_connected() { :; }
on_reconnecting() { :; }
on_disconnected() { :; }
on_chat() { :; }
on_gift() { :; }
on_like() { :; }
on_join() { :; }
on_follow() { :; }
on_share() { :; }
on_viewers() { :; }
on_top_viewer() { :; }
on_ended() { :; }
on_unknown() { :; }
on_audience_viewer() { :; }
on_status() { :; }
on_error() { echo "error: $*" >&2; }

. "$PT_LIB_DIR/pt_net.sh"
. "$PT_LIB_DIR/pt_api.sh"
. "$PT_LIB_DIR/pt_events.sh"
. "$PT_LIB_DIR/pt_helpers.sh"

# --- UA pool / locale / timezone ---
pt_random_ua() {
    case $(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 6 )) in
        0) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0" ;;
        1) echo "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0" ;;
        2) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5; rv:128.0) Gecko/20100101 Firefox/128.0" ;;
        3) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" ;;
        4) echo "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" ;;
        *) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" ;;
    esac
}

pt_locale() {
    _pl=${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}
    _pl=${_pl%%.*}
    case $_pl in
        [a-z][a-z]_[A-Z][A-Z]*) _pl_lang=${_pl%%_*}; _pl_reg=${_pl#*_}; _pl_reg=$(printf '%.2s' "$_pl_reg") ;;
        *) _pl_lang=en; _pl_reg=US ;;
    esac
    PT_LANG_EFFECTIVE=${PT_LANGUAGE:-$_pl_lang}
    PT_REGION_EFFECTIVE=${PT_REGION:-$_pl_reg}
}

pt_system_tz() {
    if [ -n "$TZ" ] && case $TZ in */*) true ;; *) false ;; esac; then echo "$TZ"; return; fi
    if [ -f /etc/timezone ]; then _pt_tz=$(cat /etc/timezone); case $_pt_tz in */*) echo "$_pt_tz"; return ;; esac; fi
    if [ -L /etc/localtime ]; then _pt_tz=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||'); case $_pt_tz in */*) echo "$_pt_tz"; return ;; esac; fi
    echo "UTC"
}

# --- reconnect policy (pure; unit-tested) ---
# pt_judge EXIT LIVED_SEC -> PT_END (healthy|failed|blocked), PT_SESSION_ACTION (keep|rotate)
pt_judge() {
    if [ "$2" -ge "$PT_HEALTHY_SEC" ]; then _pj_end=healthy; else _pj_end=failed; fi
    case $1 in
        closed) PT_END=$_pj_end; PT_SESSION_ACTION=keep ;;
        blocked) PT_END=blocked; PT_SESSION_ACTION=rotate ;;
        errored) PT_END=$_pj_end; [ "$_pj_end" = healthy ] && PT_SESSION_ACTION=keep || PT_SESSION_ACTION=rotate ;;
        *) PT_END=failed; PT_SESSION_ACTION=rotate ;;
    esac
}

# pt_budget_record END -> PT_VERDICT (retry|giveup), PT_ATTEMPT, PT_DELAY. Reset PT_ATTEMPT=0 first.
pt_budget_record() {
    case $1 in
        healthy) PT_ATTEMPT=1 ;;
        *) PT_ATTEMPT=$((PT_ATTEMPT + 1)) ;;
    esac
    if [ "$PT_ATTEMPT" -gt "$PT_MAX_RETRIES" ]; then PT_VERDICT=giveup; return; fi
    PT_VERDICT=retry
    if [ "$1" = blocked ]; then PT_DELAY=$PT_BLOCKED_DELAY; return; fi
    PT_DELAY=2
    _pb_i=1
    while [ "$_pb_i" -lt "$PT_ATTEMPT" ] && [ "$PT_DELAY" -lt "$PT_MAX_BACKOFF" ]; do PT_DELAY=$((PT_DELAY * 2)); _pb_i=$((_pb_i + 1)); done
    [ "$PT_DELAY" -gt "$PT_MAX_BACKOFF" ] && PT_DELAY=$PT_MAX_BACKOFF
    return 0
}

# --- client ---
pt_disconnect() {
    _PT_STOP=1
    [ -n "$_PT_SSL_PID" ] && kill "$_PT_SSL_PID" 2>/dev/null
    return 0
}

_pt_attempt() {
    if [ -z "$PT_TTWID" ]; then
        _PT_UA_SESSION=${PT_UA:-$(pt_random_ua)}
        if ! pt_fetch_ttwid; then
            on_status "ttwid acquisition failed: $PT_ERROR"
            _PT_EXIT=nottwid; _PT_LIVED=0; return
        fi
    fi
    _pa_start=$(date +%s)
    pt_wss_open
    case $? in
        0) pt_read_loop; _PT_EXIT=closed ;;
        2) _PT_EXIT=blocked; on_status "DEVICE_BLOCKED - rotating ttwid + UA" ;;
        *) _PT_EXIT=errored; on_status "websocket error: $PT_ERROR" ;;
    esac
    pt_wss_close
    _PT_LIVED=$(( $(date +%s) - _pa_start ))
}

# pt_connect USERNAME - blocking: resolve room, then reconnect loop until pt_disconnect or budget exhausted
pt_connect() {
    _pc_user=$(echo "$1" | sed 's/^@//')
    pt_resolve_room "$_pc_user"
    [ "$PT_ONLINE" = LIVE ] || { on_error "$PT_ERROR"; return 1; }
    PT_TTWID=""; PT_ATTEMPT=0; _PT_STOP=0
    on_connected "$PT_ROOM_ID"
    on_status "connected to $_pc_user (room $PT_ROOM_ID)"
    while :; do
        _pt_attempt
        [ "$_PT_STOP" = 1 ] && break
        pt_judge "$_PT_EXIT" "$_PT_LIVED"
        [ "$PT_SESSION_ACTION" = rotate ] && PT_TTWID=""
        pt_budget_record "$PT_END"
        [ "$PT_VERDICT" = giveup ] && break
        on_reconnecting "$PT_ATTEMPT" "$PT_MAX_RETRIES" "$PT_DELAY"
        sleep "$PT_DELAY"
    done
    on_disconnected
}
