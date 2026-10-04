#!/bin/sh
# Offline unit tests: reconnect policy, parsers (F1/F9/F10/F16), decoder + dispatch (F11-F13),
# helpers (F14-F16), URL params (F3/F8), proxy parsing (F6), JSON. usage: sh tests/unit.sh
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PT_LIB_DIR=$ROOT/lib
. "$ROOT/lib/piratetok.sh"
_pt_tmp
PASS=0
FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "ok   $1"; else FAIL=$((FAIL + 1)); echo "FAIL $1: got [$2] want [$3]"; fi; }
has() { case $2 in *"$3"*) eq "$1" x x ;; *) eq "$1" "$2" "*$3*" ;; esac; }
fx() { printf '%s' "$2" > "$_PT_DIR/fx.$1"; echo "$_PT_DIR/fx.$1"; }

# --- reconnect policy (F4/F5) ---
pt_judge closed 3; eq "judge closed short" "$PT_END/$PT_SESSION_ACTION" failed/keep
pt_judge closed 600; eq "judge closed healthy" "$PT_END/$PT_SESSION_ACTION" healthy/keep
pt_judge blocked 600; eq "judge device blocked" "$PT_END/$PT_SESSION_ACTION" blocked/rotate
pt_judge errored 3; eq "judge errored short" "$PT_END/$PT_SESSION_ACTION" failed/rotate
pt_judge errored 600; eq "judge errored healthy" "$PT_END/$PT_SESSION_ACTION" healthy/keep
pt_judge nottwid 0; eq "judge no ttwid" "$PT_END/$PT_SESSION_ACTION" failed/rotate
PT_MAX_RETRIES=5 PT_ATTEMPT=0; _seq=""
for _i in 1 2 3 4 5 6; do pt_budget_record failed; _seq="$_seq $PT_VERDICT:$PT_ATTEMPT:${PT_DELAY}"; done
eq "budget backoff then give up" "$_seq" " retry:1:2 retry:2:4 retry:3:8 retry:4:16 retry:5:30 giveup:6:30"
PT_MAX_RETRIES=3 PT_ATTEMPT=3; pt_budget_record healthy; eq "healthy session resets budget" "$PT_VERDICT:$PT_ATTEMPT:$PT_DELAY" retry:1:2
PT_ATTEMPT=0; pt_budget_record blocked; eq "device blocked short delay" "$PT_VERDICT:$PT_ATTEMPT:$PT_DELAY" retry:1:2
PT_MAX_RETRIES=0 PT_ATTEMPT=0; pt_budget_record healthy; eq "max_retries 0 = one attempt" "$PT_VERDICT" giveup
PT_MAX_RETRIES=5

# --- F1 room resolution ---
pt_parse_room_response u 200 "$(fx room '{"statusCode":0,"data":{"user":{"roomId":"7001","id":"7378524586521674757","status":2},"liveRoom":{"status":2}}}')"
eq "F1 live: room + exact int64 anchor" "$PT_ONLINE:$PT_ROOM_ID:$PT_ANCHOR_ID" LIVE:7001:7378524586521674757
pt_parse_room_response u 200 "$(fx r1 '{"statusCode":19881007}')"; eq "F1 user not found" "$PT_ONLINE:$PT_ERROR" "404:USER_NOT_FOUND: u"
pt_parse_room_response u 200 "$(fx r2 '{"statusCode":4003}')"; eq "F1 api error code" "$PT_ONLINE:$PT_ERROR" "APIERROR:API_ERROR: statusCode=4003"
pt_parse_room_response u 429 "$(fx r3 '{"statusCode":0}')"; eq "F1 429 blocked" "$PT_ONLINE:$PT_ERROR" "BLOCKED:TIKTOK_BLOCKED: http 429"
pt_parse_room_response u 403 "$(fx r4 '')"; eq "F1 403 blocked" "$PT_ONLINE" BLOCKED
pt_parse_room_response u 200 "$(fx r5 '   ')"; has "F1 empty body blocked" "$PT_ONLINE:$PT_ERROR" "BLOCKED:TIKTOK_BLOCKED: empty"
pt_parse_room_response u 200 "$(fx r6 '<html>captcha</html>')"; has "F1 non-JSON blocked" "$PT_ONLINE:$PT_ERROR" "BLOCKED:TIKTOK_BLOCKED: non-JSON"
pt_parse_room_response u 200 "$(fx r7 '{"statusCode":0,"data":{"user":{"roomId":"0"}}}')"; eq "F1 offline (no room)" "$PT_ONLINE" OFF
case $PT_ERROR in *[Bb]lock*) eq "F1 offline error does not say blocked" "$PT_ERROR" "no blocked" ;; *) eq "F1 offline error does not say blocked" ok ok ;; esac
pt_parse_room_response u 200 "$(fx r8 '{"statusCode":0,"data":{"user":{"roomId":"7001","status":4},"liveRoom":{"status":4}}}')"; eq "F1 status 4 offline" "$PT_ERROR" "HOST_NOT_ONLINE: status=4"

# --- F9 room info ---
_sd='{\"data\":{\"origin\":{\"main\":{\"flv\":\"o.flv\"}},\"uhd\":{\"main\":{\"flv\":\"uhd.flv\"}},\"sd\":{\"main\":{\"flv\":\"sd.flv\"}}}}'
pt_parse_room_info 200 "$(fx info "{\"status_code\":0,\"data\":{\"title\":\"t\",\"user_count\":12,\"owner\":{\"id_str\":\"99\"},\"stats\":{\"like_count\":34,\"total_user\":56},\"stream_url\":{\"live_core_sdk_data\":{\"pull_data\":{\"stream_data\":\"$_sd\"}}}}}")"
eq "F9 room info fields" "$PT_INFO_TITLE/$PT_INFO_VIEWERS/$PT_INFO_LIKES/$PT_INFO_TOTAL/$PT_INFO_OWNER_ID" t/12/34/56/99
eq "F9 flv urls (hd falls back to uhd)" "$PT_INFO_FLV_ORIGIN/$PT_INFO_FLV_HD/$PT_INFO_FLV_SD/$PT_INFO_FLV_LD" o.flv/uhd.flv/sd.flv/
pt_parse_room_info 200 "$(fx i2 '{"status_code":4003110}')"; has "F9 age restricted mentions cookies" "$PT_ERROR" "AGE_RESTRICTED: 18+ room - pass session cookies"
pt_parse_room_info 200 "$(fx i3 '{"status_code":10011}')"; eq "F9 other status -> api error" "$PT_ERROR" "API_ERROR: status_code=10011"

# --- F10 audience ---
on_audience_viewer() { _aud="$_aud|$1:$2:$3:$4:$5:$6:$7$8$9${10}"; }
_aud=""
pt_parse_audience 200 "$(fx aud '{"status_code":0,"data":{"total":40,"anonymous":3,"ranks":[{"rank":1,"score":900,"user":{"id_str":"11","display_id":"alice","nickname":"A","follow_info":{"follower_count":7},"verified":true,"is_follower":true,"is_following":false,"is_subscribe":true}},{"rank":2,"score":5},{"rank":3,"score":1,"user":{"id":22,"display_id":"bob","nickname":"B"}}]}}')"
eq "F10 roster totals" "$PT_AUD_TOTAL/$PT_AUD_ANON" 40/3
eq "F10 named viewers (userless skipped, id fallback, flags)" "$_aud" "|1:900:11:alice:A:7:1101|3:1:22:bob:B:0:0000"
pt_parse_audience 200 "$(fx a2 '{"status_code":20003}')"; has "F10 session required" "$PT_ERROR" "SESSION_REQUIRED: audience roster needs login"
pt_parse_audience 200 "$(fx a3 '{"status_code":10011,"data":{"message":"bad anchor"}}')"; eq "F10 other status" "$PT_ERROR" "INVALID_RESPONSE: online_audience status_code=10011 bad anchor"

# --- F16 profile parse ---
_html='<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">{"__DEFAULT_SCOPE__":{"webapp.user-detail":{"statusCode":STATUS,"userInfo":{"user":{"id":"1","uniqueId":"alice","nickname":"Alice","avatarLarger":"l.jpg","verified":true,"bioLink":{"link":"x.y"}},"stats":{"followerCount":10}}}}}</script></html>'
pt_parse_profile alice "$(fx p0 "$(printf '%s' "$_html" | sed 's/STATUS/0/')")" && _pt_load_profile "$_PT_DIR/profile.tsv"
eq "F16 profile fields" "$PT_PROFILE_NICKNAME/$PT_PROFILE_AVATAR_LARGE/$PT_PROFILE_FOLLOWER_COUNT/$PT_PROFILE_BIO_LINK/$PT_PROFILE_VERIFIED" Alice/l.jpg/10/x.y/true
pt_parse_profile p "$(fx p1 "$(printf '%s' "$_html" | sed 's/STATUS/10222/')")"; eq "F16 private profile" "$PT_ERROR" "PROFILE_PRIVATE: @p"
pt_parse_profile p "$(fx p2 "$(printf '%s' "$_html" | sed 's/STATUS/10221/')")"; eq "F16 profile not found" "$PT_ERROR" "PROFILE_NOT_FOUND: @p"
pt_parse_profile p "$(fx p3 '<html></html>')"; has "F16 missing SIGI tag" "$PT_ERROR" "PROFILE_SCRAPE"

# --- decoder + dispatch (F11/F12/F13, Unknown passthrough, ack fields) ---
_user() { echo "$(_pt_encode_str 3 "$1")$(_pt_encode_str 38 "$2")"; }
_contrib() { echo "$(_pt_encode_uint64 1 "$1")$( [ -n "$3" ] && _pt_encode_ld 2 "$(_user "$3" "$3x")")$(_pt_encode_uint64 3 "$2")"; }
_msg() { _pt_encode_ld 1 "$(_pt_encode_str 1 "$1")$(_pt_encode_ld 2 "$2")"; }
_seq="$(_pt_encode_ld 2 "$(_contrib 10 3 c)")$(_pt_encode_ld 2 "$(_contrib 500 1 a)")$(_pt_encode_ld 2 "$(_contrib 90 2 '')")$(_pt_encode_ld 2 "$(_contrib 100 2 b)")$(_pt_encode_uint64 3 120)"
_social="$(_pt_encode_ld 2 "$(_user Dan dan)")$(_pt_encode_uint64 4 1)"
_member="$(_pt_encode_ld 2 "$(_user Mia mia)")$(_pt_encode_uint64 10 1)"
_resp="$(_msg WebcastRoomUserSeqMessage "$_seq")$(_msg WebcastSocialMessage "$_social")$(_msg WebcastMemberMessage "$_member")$(_msg WebcastMysteryMessage 0a01ff)$(_pt_encode_str 5 ext)$(_pt_encode_uint64 9 1)"
printf '%s\n' "$_resp" | pt_decode_response > "$_PT_DIR/events"
eq "ack flag + internal_ext hex" "$(head -n 1 "$_PT_DIR/events")" "A${PT_TAB}1${PT_TAB}657874"
_log=""
on_event() { _log="$_log $1"; }
on_viewers() { _log="$_log viewers=$1"; }
on_top_viewer() { _log="$_log top=$1:$2:$3:$4"; }
on_follow() { _log="$_log follow=$1"; }
on_join() { _log="$_log join=$1"; }
on_unknown() { _log="$_log unknown=$1:$2"; }
pt_dispatch_file "$_PT_DIR/events"
eq "F11-F13 dispatch: top viewers sorted, userless skipped, raw+convenience, unknown payload" "$_log" \
    " RoomUserSeq viewers=120 top=1:500:a:ax top=2:100:b:bx top=3:10:c:cx Social Follow follow=Dan (@dan) Member Join join=Mia (@mia) Unknown unknown=WebcastMysteryMessage:0a01ff"
eq "F12 every Tier A/B method is mapped" "$(grep -vc '^#' "$PT_LIB_DIR/pt_events.tsv")" 65
on_event() { :; }

# --- F15/F16 gift + like helpers, F14 badges ---
_gift() { PT_EV_FIELDS="group_id${PT_TAB}42
repeat_count${PT_TAB}$1
repeat_end${PT_TAB}$2
gift_details.gift_type${PT_TAB}$3
gift_details.diamond_count${PT_TAB}5
"; }
_gs=""
for _g in "1 0 1" "3 0 1" "3 1 1"; do set -- $_g; _gift "$@"; pt_gift_streak; _gs="$_gs $PT_STREAK_EVENT_COUNT/$PT_STREAK_FINAL/$PT_STREAK_EVENT_DIAMONDS/$PT_STREAK_TOTAL_DIAMONDS"; done
eq "F16 gift streak deltas" "$_gs" " 1/0/5/5 2/0/10/15 0/1/0/15"
_gift 1 0 0; pt_gift_streak; eq "F16 non-combo gift is final" "$PT_STREAK_FINAL/$PT_STREAK_EVENT_COUNT" 1/1
_gift 4 0 1; eq "F15 combo + diamond_total" "$(pt_gift_is_combo && echo combo)/$(pt_gift_is_streak_over || echo running)/$(pt_gift_diamond_total)" combo/running/20
_lk=""
for _l in "5 100" "3 90" "2 120"; do set -- $_l; PT_EV_FIELDS="count${PT_TAB}$1
total${PT_TAB}$2
"; pt_like_accumulate; _lk="$_lk $PT_LIKE_TOTAL:$PT_LIKE_ACCUMULATED:$PT_LIKE_BACKWARDS"; done
eq "F16 like accumulator" "$_lk" " 100:5:0 100:8:1 120:10:0"
PT_EV_FIELDS="user.badge_list.0.badge_scene${PT_TAB}8
user.badge_list.0.log_extra.level${PT_TAB}21
user.badge_list.1.badge_scene${PT_TAB}1
user.follow_info.follower_count${PT_TAB}77
"
eq "F14 badges: gifter level / moderator / top gifter" "$(pt_gifter_level)/$(pt_is_moderator && echo mod)/$(pt_is_top_gifter || echo no)" 21/mod/no

# --- F3/F8 URL params, F6 proxy parsing ---
PT_HEARTBEAT_SEC=7 PT_LANGUAGE=ro PT_REGION=RO PT_COMPRESS=0 PT_ROOM_ID=7001
_url=$(pt_ws_url_path)
for _p in heartbeat_duration=7000 browser_language=ro-RO webcast_language=ro app_language=ro "compress=&" room_id=7001; do has "F3/F8 url has $_p" "$_url" "$_p"; done
PT_COMPRESS=1; has "F8 compress on" "$(pt_ws_url_path)" "compress=gzip"
PT_PROXY="http://u:p@proxy.test:3128"; _pt_proxy_parse; eq "F6 proxy userinfo" "$_PT_PROXY_HOSTPORT/$_PT_PROXY_USER/$_PT_PROXY_PASS" proxy.test:3128/u/p
PT_PROXY="http://proxy.test"; _pt_proxy_parse; eq "F6 proxy default port" "$_PT_PROXY_HOSTPORT" proxy.test:8080
PT_PROXY="socks5://127.0.0.1:1080"; _pt_proxy_parse; has "F6 socks is a documented limit" "$PT_ERROR" "no SOCKS"
PT_PROXY=""

# --- JSON flattener + frame round trip ---
_jf=$(printf '%s' '{"a":{"b":[1,{"c":"x\"yé😀"}]},"n":9223372036854775807}' | LC_ALL=C awk -f "$PT_LIB_DIR/pt_json.awk")
eq "json flatten (escapes, surrogates, int64 text)" "$_jf" "a.b.0${PT_TAB}1
a.b.1.c${PT_TAB}x\"yé😀
n${PT_TAB}9223372036854775807"
printf '{"a":' | LC_ALL=C awk -f "$PT_LIB_DIR/pt_json.awk" >/dev/null; eq "json malformed exits 2" "$?" 2
PT_ROOM_ID=7001
eq "heartbeat frame decodes" "$(printf '%s\n' "$(_pt_build_heartbeat)" | _pt_awk -v schema="$PT_LIB_DIR/piratetok.proto" -v mode=frame -f "$PT_LIB_DIR/pt_proto.awk" | cut -f1,3)" "hb${PT_TAB}08d936"
eq "ack frame decodes" "$(printf '%s\n' "$(_pt_build_ack 77 c3ff00)" | _pt_awk -v schema="$PT_LIB_DIR/piratetok.proto" -v mode=frame -f "$PT_LIB_DIR/pt_proto.awk")" "ack${PT_TAB}77${PT_TAB}c3ff00"

rm -rf "$_PT_DIR"
echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
