#!/bin/sh
# piratetok.sh — TikTok Live connector library (POSIX sh)
# Source this file, define event handlers, call pt_connect.
# Dependencies: sh, openssl, gzip
#
# Event handlers (define before calling pt_connect):
#   on_chat  USER CONTENT
#   on_gift  USER GIFT_NAME REPEAT DIAMONDS
#   on_like  USER TOTAL
#   on_join  USER
#   on_follow USER
#   on_share USER
#   on_viewers COUNT
#   on_ended
#   on_status MESSAGE
#   on_error  MESSAGE          (fatal — called before exit)
#
# High-level:
#   pt_connect USERNAME        (blocking: auth → room → wss → read loop)
#
# Low-level:
#   pt_fetch_ttwid             → sets PT_TTWID
#   pt_resolve_room USERNAME   → sets PT_ROOM_ID, PT_ROOM_RESP
#   pt_wss_open                → opens WSS on fds 3/4, starts heartbeat
#   pt_read_loop               → blocking read loop, calls event handlers
#   pt_wss_close               → cleanup fds + background pids

# --- guards ---
_PT_SOURCED=1

# --- config (overridable before calling pt_*) ---
: "${PT_CDN:=webcast-ws.tiktok.com}"
: "${PT_HEARTBEAT_SEC:=10}"
: "${PT_UA:=}"

# --- UA pool ---
pt_random_ua() {
    _pt_n=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')
    : "${_pt_n:=$$}"
    case $(( _pt_n % 6 )) in
        0) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0" ;;
        1) echo "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0" ;;
        2) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5; rv:128.0) Gecko/20100101 Firefox/128.0" ;;
        3) echo "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" ;;
        4) echo "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" ;;
        5) echo "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36" ;;
    esac
}

# --- timezone detection ---
pt_system_tz() {
    # env override
    if [ -n "$TZ" ] && echo "$TZ" | grep -q '/'; then
        echo "$TZ"; return
    fi
    # /etc/timezone (Debian/Ubuntu)
    if [ -f /etc/timezone ]; then
        _pt_tz=$(cat /etc/timezone 2>/dev/null)
        if [ -n "$_pt_tz" ] && echo "$_pt_tz" | grep -q '/'; then
            echo "$_pt_tz"; return
        fi
    fi
    # /etc/localtime symlink (Arch, Fedora, macOS)
    if [ -L /etc/localtime ]; then
        _pt_tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
        if [ -n "$_pt_tz" ] && echo "$_pt_tz" | grep -q '/'; then
            echo "$_pt_tz"; return
        fi
    fi
    echo "UTC"
}

# --- default event handlers (no-ops, override these) ---
on_chat() { :; }
on_gift() { :; }
on_like() { :; }
on_join() { :; }
on_follow() { :; }
on_share() { :; }
on_viewers() { :; }
on_ended() { :; }
on_status() { :; }
on_error() { echo "error: $*" >&2; exit 1; }

# --- helpers ---
_pt_x2d() { printf '%d' "0x$1"; }
_pt_hex2bin() { printf '%s' "$1" | sed 's/../\\\\x&/g' | xargs printf > "$2"; }
_pt_hex2raw() { printf '%s' "$1" | sed 's/../\\\\x&/g' | xargs printf; }
_pt_hex2str() { printf '%s' "$1" | sed 's/../\\\\x&/g' | xargs printf 2>/dev/null; }

# --- protobuf encoder ---
_pt_encode_varint() {
    _pv=$1; _po=""
    while [ "$_pv" -gt 127 ]; do
        _pb=$(( (_pv & 127) | 128 ))
        _po="$_po$(printf '%02x' "$_pb")"
        _pv=$(( _pv >> 7 ))
    done
    _po="$_po$(printf '%02x' "$_pv")"
    echo "$_po"
}

_pt_encode_tag() { _pt_encode_varint $(( $1 * 8 + $2 )); }

_pt_encode_ld() {
    _pe_f=$1; _pe_p=$2
    _pe_l=$(( ${#_pe_p} / 2 ))
    _pe_t=$(_pt_encode_tag "$_pe_f" 2)
    _pe_n=$(_pt_encode_varint "$_pe_l")
    echo "${_pe_t}${_pe_n}${_pe_p}"
}

_pt_encode_str() {
    _pe_h=$(printf '%s' "$2" | od -An -tx1 | tr -d ' \n')
    _pt_encode_ld "$1" "$_pe_h"
}

_pt_encode_uint64() {
    _pe_t=$(_pt_encode_tag "$1" 0)
    _pe_v=$(_pt_encode_varint "$2")
    echo "${_pe_t}${_pe_v}"
}

# --- protobuf decoder ---
_pt_decode_varint() {
    _dv_hex=$1; _dv_off=$2
    DV_VAL=0; _dv_mul=1
    while true; do
        _dv_byte=$(_pt_x2d "$(echo "$_dv_hex" | cut -c$((_dv_off+1))-$((_dv_off+2)))")
        _dv_off=$((_dv_off + 2))
        DV_VAL=$(( DV_VAL + (_dv_byte & 127) * _dv_mul ))
        _dv_mul=$(( _dv_mul * 128 ))
        [ $((_dv_byte & 128)) -eq 0 ] && break
    done
    DV_NEWOFF=$_dv_off
}

_pt_proto_decode() {
    _pd_hex=$1; _pd_len=${#_pd_hex}; _pd_off=0
    while [ "$_pd_off" -lt "$_pd_len" ]; do
        _pt_decode_varint "$_pd_hex" "$_pd_off"
        _pd_tag=$DV_VAL; _pd_off=$DV_NEWOFF
        _pd_fnum=$((_pd_tag >> 3))
        _pd_wtype=$((_pd_tag & 7))
        [ "$_pd_fnum" -eq 0 ] && break
        case $_pd_wtype in
            0)
                _pt_decode_varint "$_pd_hex" "$_pd_off"
                _pd_off=$DV_NEWOFF
                echo "${_pd_fnum}:0:${DV_VAL}"
                ;;
            2)
                _pt_decode_varint "$_pd_hex" "$_pd_off"
                _pd_dlen=$DV_VAL; _pd_off=$DV_NEWOFF
                if [ "$_pd_dlen" -gt 0 ]; then
                    _pd_data=$(echo "$_pd_hex" | cut -c$((_pd_off+1))-$((_pd_off + _pd_dlen*2)))
                else
                    _pd_data=""
                fi
                _pd_off=$((_pd_off + _pd_dlen * 2))
                echo "${_pd_fnum}:2:${_pd_data}"
                ;;
            1) _pd_off=$((_pd_off + 16)) ;;
            5) _pd_off=$((_pd_off + 8)) ;;
            *) break ;;
        esac
    done
}

_pt_proto_field() { echo "$2" | grep "^${1}:" | head -1 | cut -d: -f3-; }

# --- user decoder ---
pt_decode_user() {
    _du_fields=$(_pt_proto_decode "$1")
    _du_nick=$(_pt_hex2str "$(_pt_proto_field 3 "$_du_fields")")
    _du_uid=$(_pt_hex2str "$(_pt_proto_field 38 "$_du_fields")")
    [ -z "$_du_nick" ] && _du_nick="?"
    echo "${_du_nick}${_du_uid:+ (@${_du_uid})}"
}

# --- HTTP via openssl s_client ---
_pt_http_get() {
    _hg_host=$1; _hg_path=$2; _hg_cookie=$3
    {
        printf 'GET %s HTTP/1.1\r\n' "$_hg_path"
        printf 'Host: %s\r\n' "$_hg_host"
        printf 'User-Agent: %s\r\n' "$PT_UA"
        printf 'Accept: */*\r\n'
        printf 'Connection: close\r\n'
        [ -n "$_hg_cookie" ] && printf 'Cookie: %s\r\n' "$_hg_cookie"
        printf '\r\n'
    } | openssl s_client -connect "${_hg_host}:443" -quiet 2>/dev/null
}

# --- frame builders ---
_pt_build_heartbeat() {
    _bh_inner=$(_pt_encode_uint64 1 "$PT_ROOM_ID")
    _bh_p=$(_pt_encode_str 6 "pb")$(_pt_encode_str 7 "hb")$(_pt_encode_ld 8 "$_bh_inner")
    echo "$_bh_p"
}

_pt_build_enter_room() {
    _be_inner="$(_pt_encode_uint64 1 "$PT_ROOM_ID")$(_pt_encode_uint64 4 12)"
    _be_inner="${_be_inner}$(_pt_encode_str 5 "audience")$(_pt_encode_str 9 "0")"
    _be_p=$(_pt_encode_str 6 "pb")$(_pt_encode_str 7 "im_enter_room")$(_pt_encode_ld 8 "$_be_inner")
    echo "$_be_p"
}

_pt_build_ack() {
    _ba_logid=$1; _ba_ext=$2
    _ba_p="$(_pt_encode_str 6 "pb")$(_pt_encode_str 7 "ack")"
    _ba_p="${_ba_p}$(_pt_encode_uint64 2 "$_ba_logid")$(_pt_encode_ld 8 "$_ba_ext")"
    echo "$_ba_p"
}

# --- websocket framing ---
_pt_ws_send() {
    _ws_hex=$1; _ws_len=$(( ${#_ws_hex} / 2 ))
    _ws_mask=$(dd if=/dev/urandom bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
    _ws_m1=$(_pt_x2d "$(echo "$_ws_mask" | cut -c1-2)")
    _ws_m2=$(_pt_x2d "$(echo "$_ws_mask" | cut -c3-4)")
    _ws_m3=$(_pt_x2d "$(echo "$_ws_mask" | cut -c5-6)")
    _ws_m4=$(_pt_x2d "$(echo "$_ws_mask" | cut -c7-8)")
    _ws_hdr="82"
    if [ "$_ws_len" -lt 126 ]; then
        _ws_hdr="${_ws_hdr}$(printf '%02x' $((_ws_len | 128)))"
    elif [ "$_ws_len" -lt 65536 ]; then
        _ws_hdr="${_ws_hdr}fe$(printf '%04x' "$_ws_len")"
    else
        return 1
    fi
    _ws_hdr="${_ws_hdr}${_ws_mask}"
    _ws_masked=""; _ws_i=0
    while [ "$_ws_i" -lt "$_ws_len" ]; do
        _ws_b=$(_pt_x2d "$(echo "$_ws_hex" | cut -c$((_ws_i*2+1))-$((_ws_i*2+2)))")
        case $((_ws_i % 4)) in
            0) _ws_b=$((_ws_b ^ _ws_m1)) ;; 1) _ws_b=$((_ws_b ^ _ws_m2)) ;;
            2) _ws_b=$((_ws_b ^ _ws_m3)) ;; 3) _ws_b=$((_ws_b ^ _ws_m4)) ;;
        esac
        _ws_masked="${_ws_masked}$(printf '%02x' "$_ws_b")"
        _ws_i=$((_ws_i + 1))
    done
    _pt_hex2raw "${_ws_hdr}${_ws_masked}" >&3
}

_pt_ws_read() {
    _wr_h=$(dd bs=1 count=2 <&4 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ ${#_wr_h} -lt 4 ] && return 1
    _wr_b2=$(_pt_x2d "$(echo "$_wr_h" | cut -c3-4)")
    _wr_masked=$((_wr_b2 & 128))
    _wr_plen=$((_wr_b2 & 127))
    if [ "$_wr_plen" -eq 126 ]; then
        _wr_ext=$(dd bs=1 count=2 <&4 2>/dev/null | od -An -tx1 | tr -d ' \n')
        _wr_plen=$(_pt_x2d "$_wr_ext")
    elif [ "$_wr_plen" -eq 127 ]; then
        _wr_ext=$(dd bs=1 count=8 <&4 2>/dev/null | od -An -tx1 | tr -d ' \n')
        _wr_plen=$(_pt_x2d "$(echo "$_wr_ext" | cut -c9-16)")
    fi
    if [ "$_wr_masked" -ne 0 ]; then
        dd bs=1 count=4 <&4 >/dev/null 2>&1
    fi
    PT_WS_FRAME=$(dd bs=1 count="$_wr_plen" <&4 2>/dev/null | od -An -tx1 | tr -d ' \n')
}

# --- message dispatch ---
_pt_process_message() {
    _pm_method=$1; _pm_hex=$2
    case "$_pm_method" in
        WebcastChatMessage)
            _pm_f=$(_pt_proto_decode "$_pm_hex")
            _pm_uh=$(_pt_proto_field 2 "$_pm_f")
            _pm_content=$(_pt_hex2str "$(_pt_proto_field 3 "$_pm_f")")
            _pm_who=$(pt_decode_user "$_pm_uh")
            on_chat "$_pm_who" "$_pm_content"
            ;;
        WebcastGiftMessage)
            _pm_f=$(_pt_proto_decode "$_pm_hex")
            _pm_uh=$(_pt_proto_field 7 "$_pm_f")
            _pm_who=$(pt_decode_user "$_pm_uh")
            _pm_repeat=$(_pt_proto_field 5 "$_pm_f")
            : "${_pm_repeat:=1}"
            _pm_gh=$(_pt_proto_field 15 "$_pm_f")
            _pm_gname=""; _pm_diamonds=0
            if [ -n "$_pm_gh" ]; then
                _pm_gf=$(_pt_proto_decode "$_pm_gh")
                _pm_gname=$(_pt_hex2str "$(_pt_proto_field 16 "$_pm_gf")")
                _pm_diamonds=$(_pt_proto_field 12 "$_pm_gf")
                : "${_pm_diamonds:=0}"
            fi
            on_gift "$_pm_who" "${_pm_gname:-gift}" "$_pm_repeat" "$_pm_diamonds"
            ;;
        WebcastLikeMessage)
            _pm_f=$(_pt_proto_decode "$_pm_hex")
            _pm_uh=$(_pt_proto_field 5 "$_pm_f")
            _pm_who=$(pt_decode_user "$_pm_uh")
            _pm_total=$(_pt_proto_field 3 "$_pm_f")
            on_like "$_pm_who" "${_pm_total:-?}"
            ;;
        WebcastMemberMessage)
            _pm_f=$(_pt_proto_decode "$_pm_hex")
            _pm_uh=$(_pt_proto_field 2 "$_pm_f")
            _pm_who=$(pt_decode_user "$_pm_uh")
            on_join "$_pm_who"
            ;;
        WebcastSocialMessage)
            _pm_f=$(_pt_proto_decode "$_pm_hex")
            _pm_uh=$(_pt_proto_field 2 "$_pm_f")
            _pm_who=$(pt_decode_user "$_pm_uh")
            _pm_action=$(_pt_proto_field 3 "$_pm_f")
            case "$_pm_action" in
                1) on_follow "$_pm_who" ;;
                3|4) on_share "$_pm_who" ;;
            esac
            ;;
        WebcastRoomUserSeqMessage)
            _pm_f=$(_pt_proto_decode "$_pm_hex")
            _pm_vc=$(_pt_proto_field 3 "$_pm_f")
            [ -n "$_pm_vc" ] && on_viewers "$_pm_vc"
            ;;
        WebcastControlMessage)
            _pm_f=$(_pt_proto_decode "$_pm_hex")
            _pm_action=$(_pt_proto_field 2 "$_pm_f")
            [ "$_pm_action" = "3" ] && on_ended
            ;;
    esac
}

_pt_process_frame() {
    _pf_hex=$1
    _pf_f=$(_pt_proto_decode "$_pf_hex")
    _pf_ptype=$(_pt_hex2str "$(_pt_proto_field 7 "$_pf_f")")
    [ "$_pf_ptype" != "msg" ] && return

    _pf_raw=$(_pt_proto_field 8 "$_pf_f")
    _pf_magic=$(echo "$_pf_raw" | cut -c1-4)
    if [ "$_pf_magic" = "1f8b" ]; then
        _pt_hex2bin "$_pf_raw" "$_PT_TMP/gz.bin"
        _pf_raw=$(gzip -dc < "$_PT_TMP/gz.bin" | od -An -tx1 | tr -d ' \n')
    fi

    _pf_resp=$(_pt_proto_decode "$_pf_raw")

    _pf_ack=$(_pt_proto_field 9 "$_pf_resp")
    _pf_ext=$(_pt_proto_field 5 "$_pf_resp")
    if [ "$_pf_ack" = "1" ] && [ -n "$_pf_ext" ]; then
        _pf_logid=$(_pt_proto_field 2 "$_pf_f")
        _pt_ws_send "$(_pt_build_ack "$_pf_logid" "$_pf_ext")" 2>/dev/null
    fi

    echo "$_pf_resp" | grep '^1:2:' | while IFS= read -r _pf_line; do
        _pf_mhex=$(echo "$_pf_line" | cut -d: -f3-)
        _pf_mf=$(_pt_proto_decode "$_pf_mhex")
        _pf_method=$(_pt_hex2str "$(_pt_proto_field 1 "$_pf_mf")")
        _pf_mpay=$(_pt_proto_field 2 "$_pf_mf")
        _pt_process_message "$_pf_method" "$_pf_mpay"
    done
}

# --- public API ---

pt_fetch_ttwid() {
    [ -z "$PT_UA" ] && PT_UA=$(pt_random_ua)
    on_status "fetching ttwid..."
    _ft_resp=$(_pt_http_get "www.tiktok.com" "/" "")
    PT_TTWID=$(echo "$_ft_resp" | grep -i 'set-cookie:.*ttwid=' | head -1 | \
        sed 's/.*ttwid=//;s/;.*//')
    [ -z "$PT_TTWID" ] && { on_error "no ttwid cookie returned"; return 1; }
    return 0
}

pt_resolve_room() {
    _rr_user=$1
    on_status "resolving room for $_rr_user..."
    _rr_path="/api-live/user/room?aid=1988&app_name=tiktok_web&device_platform=web_pc&app_language=en&browser_language=en-US&user_is_login=false&sourceType=54&uniqueId=${_rr_user}"
    PT_ROOM_RESP=$(_pt_http_get "www.tiktok.com" "$_rr_path" "")
    _rr_sc=$(echo "$PT_ROOM_RESP" | grep -o '"statusCode":[0-9]*' | head -1 | sed 's/.*://')
    case "$_rr_sc" in
        0) ;;
        19881007) on_error "user '$_rr_user' not found"; return 1 ;;
        "") on_error "tiktok blocked request (no statusCode)"; return 1 ;;
        *) on_error "tiktok api error: statusCode=$_rr_sc"; return 1 ;;
    esac
    PT_ROOM_ID=$(echo "$PT_ROOM_RESP" | grep -o '"roomId":"[0-9]*' | head -1 | sed 's/.*"//')
    if [ -z "$PT_ROOM_ID" ] || [ "$PT_ROOM_ID" = "0" ]; then
        on_error "$_rr_user is not live"
        return 1
    fi
    return 0
}

pt_check_online() {
    _co_user=$(echo "$1" | sed 's/^@//')
    [ -z "$PT_UA" ] && PT_UA=$(pt_random_ua)
    _co_path="/api-live/user/room?aid=1988&app_name=tiktok_web&device_platform=web_pc&app_language=en&browser_language=en-US&user_is_login=false&sourceType=54&uniqueId=${_co_user}"
    _co_resp=$(_pt_http_get "www.tiktok.com" "$_co_path" "")
    _co_sc=$(echo "$_co_resp" | grep -o '"statusCode":[0-9]*' | head -1 | sed 's/.*://')
    case "$_co_sc" in
        0)
            _co_rid=$(echo "$_co_resp" | grep -o '"roomId":"[0-9]*' | head -1 | sed 's/.*"//')
            if [ -n "$_co_rid" ] && [ "$_co_rid" != "0" ]; then
                echo "LIVE:$_co_rid"
            else
                echo "OFF"
            fi
            ;;
        19881007) echo "404" ;;
        "") echo "BLOCKED" ;;
        *) echo "ERROR:$_co_sc" ;;
    esac
}

pt_wss_open() {
    _PT_TMP=$(mktemp -d)
    _PT_FIFO_IN="$_PT_TMP/ws_in"
    _PT_FIFO_OUT="$_PT_TMP/ws_out"
    mkfifo "$_PT_FIFO_IN" "$_PT_FIFO_OUT"

    _pt_tz=$(pt_system_tz)
    _wo_path="/webcast/im/ws_proxy/ws_reuse_supplement/?version_code=180800&device_platform=web&cookie_enabled=true&screen_width=1920&screen_height=1080&browser_language=en-US&browser_platform=Linux+x86_64&browser_name=Mozilla&browser_version=5.0+(X11)&browser_online=true&tz_name=${_pt_tz}&app_name=tiktok_web&sup_ws_ds_opt=1&update_version_code=2.0.0&compress=gzip&webcast_language=en&ws_direct=1&aid=1988&live_id=12&app_language=en&client_enter=1&room_id=${PT_ROOM_ID}&identity=audience&history_comment_count=6&last_rtt=150&heartbeat_duration=10000&resp_content_type=protobuf&did_rule=3"
    _wo_key=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | openssl enc -base64)

    openssl s_client -connect "${PT_CDN}:443" -quiet < "$_PT_FIFO_IN" > "$_PT_FIFO_OUT" 2>/dev/null &
    _PT_SSL_PID=$!
    exec 3> "$_PT_FIFO_IN"
    exec 4< "$_PT_FIFO_OUT"
    sleep 1

    {
        printf 'GET %s HTTP/1.1\r\n' "$_wo_path"
        printf 'Host: %s\r\n' "$PT_CDN"
        printf 'Upgrade: websocket\r\n'
        printf 'Connection: Upgrade\r\n'
        printf 'Sec-WebSocket-Key: %s\r\n' "$_wo_key"
        printf 'Sec-WebSocket-Version: 13\r\n'
        printf 'Origin: https://www.tiktok.com\r\n'
        printf 'User-Agent: %s\r\n' "$PT_UA"
        printf 'Cookie: ttwid=%s\r\n' "$PT_TTWID"
        printf '\r\n'
    } >&3

    while IFS= read -r _wo_line <&4; do
        _wo_line=$(echo "$_wo_line" | tr -d '\r')
        [ -z "$_wo_line" ] && break
    done

    _pt_ws_send "$(_pt_build_heartbeat)"
    sleep 0.2
    _pt_ws_send "$(_pt_build_enter_room)"

    (
        while true; do
            sleep "$PT_HEARTBEAT_SEC"
            _pt_ws_send "$(_pt_build_heartbeat)" 2>/dev/null || exit 0
        done
    ) &
    _PT_HB_PID=$!
}

pt_read_loop() {
    _PT_STREAM_ENDED=0
    while true; do
        _pt_ws_read || break
        [ -z "$PT_WS_FRAME" ] && continue
        _pt_process_frame "$PT_WS_FRAME"
        [ "$_PT_STREAM_ENDED" = "1" ] && break
    done
}

pt_wss_close() {
    exec 3>&- 2>/dev/null
    exec 4<&- 2>/dev/null
    [ -n "$_PT_SSL_PID" ] && kill "$_PT_SSL_PID" 2>/dev/null
    [ -n "$_PT_HB_PID" ] && kill "$_PT_HB_PID" 2>/dev/null
    wait "$_PT_SSL_PID" "$_PT_HB_PID" 2>/dev/null
    [ -n "$_PT_TMP" ] && rm -rf "$_PT_TMP"
    _PT_SSL_PID=""; _PT_HB_PID=""; _PT_TMP=""
}

# convenience: auth → room → wss → read loop → close
pt_connect() {
    _pc_user=$(echo "$1" | sed 's/^@//')
    pt_fetch_ttwid || return 1
    pt_resolve_room "$_pc_user" || return 1
    on_status "connected to $_pc_user (room $PT_ROOM_ID)"
    pt_wss_open
    pt_read_loop
    pt_wss_close
}
