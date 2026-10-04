# pt_net.sh - TLS/proxy transport, HTTP GET, WebSocket framing, protobuf frame builders.
# Sourced by piratetok.sh.

_pt_tmp() {
    if [ -z "$_PT_DIR" ] || [ ! -d "$_PT_DIR" ]; then _PT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/piratetok.XXXXXX") || return 1; fi
}

_pt_awk() { LC_ALL=C awk "$@"; }

# --- proxy: http://[user:pass@]host:port (HTTP CONNECT via openssl -proxy) ---
_pt_proxy_parse() {
    case $PT_PROXY in
        http://* | https://*) _pp=${PT_PROXY#*://} ;;
        socks*) PT_ERROR="unsupported proxy '$PT_PROXY': openssl s_client only tunnels through HTTP CONNECT proxies (no SOCKS)"; return 1 ;;
        *) PT_ERROR="unsupported proxy '$PT_PROXY' (expected http://[user:pass@]host:port)"; return 1 ;;
    esac
    _pp=${_pp%%/*}
    _PT_PROXY_USER=""; _PT_PROXY_PASS=""
    case $_pp in *@*) _ppc=${_pp%@*}; _pp=${_pp##*@}; _PT_PROXY_USER=${_ppc%%:*}; _PT_PROXY_PASS=${_ppc#*:} ;; esac
    case $_pp in *:*) _PT_PROXY_HOSTPORT=$_pp ;; *) _PT_PROXY_HOSTPORT="$_pp:8080" ;; esac
}

# _pt_openssl HOST PORT : stdin -> TLS server -> stdout (through PT_PROXY when set)
_pt_openssl() {
    _po_host=$1
    set -- s_client -connect "$1:$2" -quiet -verify_return_error
    case $_po_host in
        *[!0-9.]*) set -- "$@" -servername "$_po_host" -verify_hostname "$_po_host" ;;
        *) set -- "$@" -verify_ip "$_po_host" ;;
    esac
    [ -n "$PT_CAFILE" ] && set -- "$@" -CAfile "$PT_CAFILE"
    if [ -n "$PT_PROXY" ]; then
        _pt_proxy_parse || return 1
        set -- "$@" -proxy "$_PT_PROXY_HOSTPORT"
        [ -n "$_PT_PROXY_USER" ] && set -- "$@" -proxy_user "$_PT_PROXY_USER" -proxy_pass "pass:$_PT_PROXY_PASS"
    fi
    openssl "$@" 2>>"$_PT_DIR/openssl.log"
}

# pt_http_get HOST PORT PATH [COOKIE] -> PT_HTTP_STATUS, files $_PT_DIR/http.headers + http.body
# returns 1 on transport failure (nothing received)
pt_http_get() {
    _pt_tmp || return 1
    PT_ERROR=""
    if [ -n "$PT_PROXY" ]; then _pt_proxy_parse || return 1; fi
    pt_locale
    {
        printf 'GET %s HTTP/1.0\r\nHost: %s\r\n' "$3" "$1"
        printf 'User-Agent: %s\r\n' "${_PT_UA_SESSION:-${PT_UA:-$(pt_random_ua)}}"
        printf 'Accept: */*\r\nAccept-Language: %s-%s,%s;q=0.9\r\nReferer: https://www.tiktok.com/\r\n' "$PT_LANG_EFFECTIVE" "$PT_REGION_EFFECTIVE" "$PT_LANG_EFFECTIVE"
        [ -n "$4" ] && printf 'Cookie: %s\r\n' "$4"
        printf '\r\n'
    } | _pt_openssl "$1" "$2" > "$_PT_DIR/http.raw"
    if [ ! -s "$_PT_DIR/http.raw" ]; then
        PT_HTTP_STATUS=0
        PT_ERROR="${PT_ERROR:-connection to $1:$2 failed}"
        return 1
    fi
    tr -d '\r' < "$_PT_DIR/http.raw" | _pt_awk -v h="$_PT_DIR/http.headers" -v b="$_PT_DIR/http.body" \
        'NR == 1 { print > h; next } !body && $0 == "" { body = 1; next } { if (body) print > b; else print > h }'
    [ -f "$_PT_DIR/http.body" ] || : > "$_PT_DIR/http.body"
    PT_HTTP_STATUS=$(head -n 1 "$_PT_DIR/http.headers" | _pt_awk '{ print $2 + 0 }')
    rm -f "$_PT_DIR/http.raw"
    return 0
}

# --- protobuf encoders ---
_pt_encode_varint() {
    _pv=$1; _po=""
    while [ "$_pv" -gt 127 ]; do _po="$_po$(printf '%02x' $(( (_pv & 127) | 128 )))"; _pv=$((_pv >> 7)); done
    echo "$_po$(printf '%02x' "$_pv")"
}
_pt_encode_tag() { _pt_encode_varint $(( $1 * 8 + $2 )); }
_pt_encode_ld() { echo "$(_pt_encode_tag "$1" 2)$(_pt_encode_varint $(( ${#2} / 2 )))$2"; }
_pt_encode_str() { _pt_encode_ld "$1" "$(printf '%s' "$2" | od -An -tx1 -v | tr -d ' \n')"; }
_pt_encode_uint64() { echo "$(_pt_encode_tag "$1" 0)$(_pt_encode_varint "$2")"; }

_pt_build_heartbeat() { echo "$(_pt_encode_str 6 pb)$(_pt_encode_str 7 hb)$(_pt_encode_ld 8 "$(_pt_encode_uint64 1 "$PT_ROOM_ID")")"; }
_pt_build_enter_room() {
    _be="$(_pt_encode_uint64 1 "$PT_ROOM_ID")$(_pt_encode_uint64 4 12)$(_pt_encode_str 5 audience)$(_pt_encode_str 9 0)"
    echo "$(_pt_encode_str 6 pb)$(_pt_encode_str 7 im_enter_room)$(_pt_encode_ld 8 "$_be")"
}
_pt_build_ack() { echo "$(_pt_encode_uint64 2 "$1")$(_pt_encode_str 6 pb)$(_pt_encode_str 7 ack)$(_pt_encode_ld 8 "$2")"; }

# --- websocket ---
# _pt_ws_send HEX [OPCODE]  (masked client frame to fd 3)
_pt_ws_send() {
    _ws_len=$(( ${#1} / 2 ))
    _ws_mask=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
    if [ "$_ws_len" -lt 126 ]; then _ws_hdr=$(printf '%02x%02x' $((128 + ${2:-2})) $((_ws_len | 128)))
    elif [ "$_ws_len" -lt 65536 ]; then _ws_hdr=$(printf '%02xfe%04x' $((128 + ${2:-2})) "$_ws_len")
    else return 1; fi
    printf '%s\n' "$1" | _pt_awk -v hdr="$_ws_hdr" -v mask="$_ws_mask" -f "$PT_LIB_DIR/pt_mask.awk" | _pt_awk -f "$PT_LIB_DIR/pt_unhex.awk" >&3
}

# _pt_ws_read -> PT_WS_OPCODE + PT_WS_FRAME (hex payload); handles ping, fragments; returns 1 on close/EOF
_pt_ws_read() {
    PT_WS_FRAME=""
    while :; do
        _wr_h=$(dd bs=1 count=2 <&4 2>/dev/null | od -An -tx1 | tr -d ' \n')
        [ ${#_wr_h} -lt 4 ] && return 1
        _wr_b1=$(printf '%d' "0x$(printf '%.2s' "$_wr_h")")
        _wr_b2=$(printf '%d' "0x${_wr_h#??}")
        _wr_op=$((_wr_b1 & 15)); _wr_len=$((_wr_b2 & 127))
        if [ "$_wr_len" -eq 126 ]; then _wr_len=$(printf '%d' "0x$(dd bs=1 count=2 <&4 2>/dev/null | od -An -tx1 | tr -d ' \n')")
        elif [ "$_wr_len" -eq 127 ]; then _wr_len=$(printf '%d' "0x$(dd bs=1 count=8 <&4 2>/dev/null | od -An -tx1 | tr -d ' \n')"); fi
        [ $((_wr_b2 & 128)) -ne 0 ] && dd bs=1 count=4 <&4 >/dev/null 2>&1
        _wr_data=""
        [ "$_wr_len" -gt 0 ] && _wr_data=$(dd bs=1 count="$_wr_len" <&4 2>/dev/null | od -An -tx1 -v | tr -d ' \n')
        case $_wr_op in
            8) return 1 ;;
            9) _pt_ws_send "$_wr_data" 10; continue ;;
            10 | 1) continue ;;
            0) PT_WS_FRAME="$PT_WS_FRAME$_wr_data" ;;
            *) PT_WS_OPCODE=$_wr_op; PT_WS_FRAME=$_wr_data ;;
        esac
        [ $((_wr_b1 & 128)) -ne 0 ] && return 0
    done
}

pt_ws_url_path() {
    pt_locale
    _wu_tz=$(pt_system_tz | sed 's|/|%2F|g')
    _wu_cmp=""; [ "$PT_COMPRESS" = 1 ] && _wu_cmp=gzip
    printf '/webcast/im/ws_proxy/ws_reuse_supplement/?version_code=180800&device_platform=web&cookie_enabled=true&screen_width=1920&screen_height=1080&browser_language=%s-%s&browser_platform=Linux+x86_64&browser_name=Mozilla&browser_version=5.0+(X11)&browser_online=true&tz_name=%s&app_name=tiktok_web&sup_ws_ds_opt=1&update_version_code=2.0.0&compress=%s&webcast_language=%s&ws_direct=1&aid=1988&live_id=12&app_language=%s&client_enter=1&room_id=%s&identity=audience&history_comment_count=6&last_rtt=150&heartbeat_duration=%s&resp_content_type=protobuf&did_rule=3\n' \
        "$PT_LANG_EFFECTIVE" "$PT_REGION_EFFECTIVE" "$_wu_tz" "$_wu_cmp" "$PT_LANG_EFFECTIVE" "$PT_LANG_EFFECTIVE" "$PT_ROOM_ID" $((PT_HEARTBEAT_SEC * 1000))
}

# pt_wss_open -> 0 open, 2 DEVICE_BLOCKED, 1 other failure (PT_ERROR)
pt_wss_open() {
    _pt_tmp || return 1
    PT_ERROR=""
    if [ -n "$PT_PROXY" ]; then _pt_proxy_parse || return 1; fi
    rm -f "$_PT_DIR/ws_in" "$_PT_DIR/ws_out"
    mkfifo "$_PT_DIR/ws_in" "$_PT_DIR/ws_out"
    _pt_openssl "$PT_CDN" "$PT_WS_PORT" < "$_PT_DIR/ws_in" > "$_PT_DIR/ws_out" &
    _PT_SSL_PID=$!
    exec 3> "$_PT_DIR/ws_in"
    exec 4< "$_PT_DIR/ws_out"
    _wo_cookie="ttwid=$PT_TTWID"; [ -n "$PT_COOKIES" ] && _wo_cookie="$_wo_cookie; $PT_COOKIES"
    {
        printf 'GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' "$(pt_ws_url_path)" "$PT_CDN"
        printf 'Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n' "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | _pt_awk -f "$PT_LIB_DIR/pt_unhex.awk" | openssl enc -base64)"
        printf 'Origin: https://www.tiktok.com\r\nUser-Agent: %s\r\nAccept-Language: %s-%s,%s;q=0.9\r\nCookie: %s\r\n\r\n' \
            "$_PT_UA_SESSION" "$PT_LANG_EFFECTIVE" "$PT_REGION_EFFECTIVE" "$PT_LANG_EFFECTIVE" "$_wo_cookie"
    } >&3
    IFS= read -r _wo_status <&4 || { PT_ERROR="no handshake response from $PT_CDN"; return 1; }
    _wo_code=$(printf '%s' "$_wo_status" | _pt_awk '{ print $2 + 0 }')
    _wo_msg=""
    while IFS= read -r _wo_line <&4; do
        _wo_line=$(printf '%s' "$_wo_line" | tr -d '\r')
        [ -z "$_wo_line" ] && break
        case $_wo_line in [Hh]andshake-[Mm]sg:*) _wo_msg=$(printf '%s' "${_wo_line#*:}" | tr -d ' ') ;; esac
    done
    if [ "$_wo_code" != 101 ]; then
        PT_ERROR="handshake rejected: http $_wo_code handshake-msg=$_wo_msg"
        [ "$_wo_msg" = DEVICE_BLOCKED ] && return 2
        return 1
    fi
    _pt_ws_send "$(_pt_build_heartbeat)"
    _pt_ws_send "$(_pt_build_enter_room)"
    date +%s > "$_PT_DIR/alive"
    ( while sleep "$PT_HEARTBEAT_SEC"; do _pt_ws_send "$(_pt_build_heartbeat)" || exit 0; done ) &
    _PT_HB_PID=$!
    ( while sleep 1; do
        _wd_last=$(cat "$_PT_DIR/alive" 2>/dev/null) || exit 0
        [ $(( $(date +%s) - _wd_last )) -ge "$PT_STALE_SEC" ] && { kill "$_PT_SSL_PID" 2>/dev/null; exit 0; }
    done ) &
    _PT_WD_PID=$!
    return 0
}

pt_wss_close() {
    exec 3>&- 4<&-
    for _wc_pid in "$_PT_SSL_PID" "$_PT_HB_PID" "$_PT_WD_PID"; do
        [ -n "$_wc_pid" ] || continue
        kill "$_wc_pid" 2>/dev/null
        wait "$_wc_pid" 2>/dev/null
    done
    rm -f "$_PT_DIR/ws_in" "$_PT_DIR/ws_out" "$_PT_DIR/alive"
    _PT_SSL_PID=""; _PT_HB_PID=""; _PT_WD_PID=""
}

pt_read_loop() {
    while [ "$_PT_STOP" != 1 ]; do
        _pt_ws_read || break
        [ -z "$PT_WS_FRAME" ] && continue
        date +%s > "$_PT_DIR/alive"
        _pt_process_frame "$PT_WS_FRAME"
    done
}

_pt_process_frame() {
    printf '%s\n' "$1" | _pt_awk -v schema="$PT_LIB_DIR/piratetok.proto" -v mode=frame -f "$PT_LIB_DIR/pt_proto.awk" > "$_PT_DIR/frame"
    IFS=$PT_TAB read -r _pf_type _pf_logid _pf_payload < "$_PT_DIR/frame"
    [ "$_pf_type" = msg ] || return 0
    case $_pf_payload in
        1f8b*) _pf_payload=$(printf '%s\n' "$_pf_payload" | _pt_awk -f "$PT_LIB_DIR/pt_unhex.awk" | gzip -dc | od -An -tx1 -v | tr -d ' \n') ;;
    esac
    printf '%s\n' "$_pf_payload" | pt_decode_response > "$_PT_DIR/events"
    IFS=$PT_TAB read -r _ _pf_ack _pf_ext < "$_PT_DIR/events"
    [ "$_pf_ack" = 1 ] && [ -n "$_pf_ext" ] && _pt_ws_send "$(_pt_build_ack "$_pf_logid" "$_pf_ext")"
    pt_dispatch_file "$_PT_DIR/events"
}

pt_decode_response() {
    _pt_awk -v schema="$PT_LIB_DIR/piratetok.proto" -v events="$PT_LIB_DIR/pt_events.tsv" -v mode=response -f "$PT_LIB_DIR/pt_proto.awk"
}
