# pt_api.sh - HTTP API: ttwid, room resolution, room info, audience roster, profile scrape.
# Sourced by piratetok.sh. Every call sets PT_ERROR on failure ("KIND: detail") and returns non-zero.

# pt_json_flatten FILE -> $_PT_DIR/json.flat ("path<TAB>value"); returns 1 if not valid JSON
pt_json_flatten() {
    _pt_awk -f "$PT_LIB_DIR/pt_json.awk" < "$1" > "$_PT_DIR/json.flat" || return 1
    return 0
}

# pt_jget PATH [FLATFILE] -> value of a flattened path (empty if absent)
pt_jget() { _pt_awk -F "$PT_TAB" -v p="$1" '$1 == p { print $2; exit }' "${2:-$_PT_DIR/json.flat}"; }

# pt_fetch_ttwid -> PT_TTWID. Missing cookie: retried PT_TTWID_ATTEMPTS times; transport error: no retry.
pt_fetch_ttwid() {
    _ft_try=1
    on_status "fetching ttwid..."
    while :; do
        pt_http_get "$PT_WEB_HOST" "$PT_WEB_PORT" "/" || { PT_ERROR="HTTP: $PT_ERROR"; return 2; }
        PT_TTWID=$(grep -i '^set-cookie: *ttwid=' "$_PT_DIR/http.headers" | head -n 1 | sed 's/^[^=]*=//; s/;.*//')
        [ -n "$PT_TTWID" ] && return 0
        if [ "$_ft_try" -ge "$PT_TTWID_ATTEMPTS" ]; then
            PT_ERROR="INVALID_RESPONSE: no ttwid cookie after $_ft_try attempts (last http $PT_HTTP_STATUS)"
            return 1
        fi
        _ft_try=$((_ft_try + 1))
        sleep "$PT_TTWID_DELAY" 2>/dev/null || sleep 1
    done
}

# pt_resolve_room USERNAME -> PT_ONLINE (LIVE|OFF|404|APIERROR|BLOCKED|ERROR), PT_ROOM_ID, PT_ANCHOR_ID, PT_ERROR
pt_resolve_room() {
    _rr_user=$(echo "$1" | sed 's/^@//')
    PT_ROOM_ID=""; PT_ANCHOR_ID=""
    pt_locale
    _rr_path="/api-live/user/room?aid=1988&app_name=tiktok_web&device_platform=web_pc&app_language=$PT_LANG_EFFECTIVE&browser_language=$PT_LANG_EFFECTIVE-$PT_REGION_EFFECTIVE&region=$PT_REGION_EFFECTIVE&user_is_login=false&uniqueId=$_rr_user&sourceType=54&staleTime=600000"
    pt_http_get "$PT_WEB_HOST" "$PT_WEB_PORT" "$_rr_path" || { PT_ONLINE=ERROR; PT_ERROR="HTTP: $PT_ERROR"; return 1; }
    pt_parse_room_response "$_rr_user" "$PT_HTTP_STATUS" "$_PT_DIR/http.body"
}

# pt_parse_room_response USERNAME HTTP_STATUS BODYFILE (pure; unit-tested)
pt_parse_room_response() {
    case $2 in 403 | 429) PT_ONLINE=BLOCKED; PT_ERROR="TIKTOK_BLOCKED: http $2"; return 1 ;; esac
    if ! grep -q '[^[:space:]]' "$3"; then PT_ONLINE=BLOCKED; PT_ERROR="TIKTOK_BLOCKED: empty response (http $2)"; return 1; fi
    if ! pt_json_flatten "$3"; then PT_ONLINE=BLOCKED; PT_ERROR="TIKTOK_BLOCKED: non-JSON response (http $2)"; return 1; fi
    _rr_sc=$(pt_jget statusCode)
    case $_rr_sc in
        "") PT_ONLINE=ERROR; PT_ERROR="INVALID_RESPONSE: no statusCode in response"; return 1 ;;
        0) ;;
        19881007) PT_ONLINE=404; PT_ERROR="USER_NOT_FOUND: $1"; return 1 ;;
        *) PT_ONLINE=APIERROR; PT_ERROR="API_ERROR: statusCode=$_rr_sc"; return 1 ;;
    esac
    PT_ROOM_ID=$(pt_jget data.user.roomId)
    PT_ANCHOR_ID=$(pt_jget data.user.id)
    _rr_st=$(pt_jget data.liveRoom.status); [ -z "$_rr_st" ] && _rr_st=$(pt_jget data.user.status)
    if [ -z "$PT_ROOM_ID" ] || [ "$PT_ROOM_ID" = 0 ]; then PT_ONLINE=OFF; PT_ERROR="HOST_NOT_ONLINE: no active room"; return 1; fi
    if [ "$_rr_st" != 2 ]; then PT_ONLINE=OFF; PT_ERROR="HOST_NOT_ONLINE: status=${_rr_st:-missing}"; return 1; fi
    PT_ONLINE=LIVE
    return 0
}

# pt_check_online USERNAME -> prints LIVE:room:anchor | OFF | 404 | APIERROR:code | BLOCKED | ERROR
pt_check_online() {
    pt_resolve_room "$1"
    case $PT_ONLINE in
        LIVE) echo "LIVE:$PT_ROOM_ID:$PT_ANCHOR_ID" ;;
        APIERROR) echo "APIERROR:${PT_ERROR##*=}" ;;
        *) echo "$PT_ONLINE" ;;
    esac
}

# pt_fetch_room_info ROOM_ID [COOKIES] -> PT_INFO_TITLE/VIEWERS/LIKES/TOTAL, PT_INFO_FLV_ORIGIN/HD/SD/LD/AO, PT_INFO_JSON (file)
pt_fetch_room_info() {
    pt_locale
    _ri_path="/webcast/room/info/?aid=1988&app_name=tiktok_web&device_platform=web_pc&app_language=$PT_LANG_EFFECTIVE&browser_language=$PT_LANG_EFFECTIVE-$PT_REGION_EFFECTIVE&webcast_language=$PT_LANG_EFFECTIVE&room_id=$1"
    pt_http_get "$PT_WEBCAST_HOST" "$PT_WEBCAST_PORT" "$_ri_path" "$2" || { PT_ERROR="HTTP: $PT_ERROR"; return 1; }
    cp "$_PT_DIR/http.body" "$_PT_DIR/room_info.json"
    PT_INFO_JSON="$_PT_DIR/room_info.json"
    pt_parse_room_info "$PT_HTTP_STATUS" "$PT_INFO_JSON"
}

# pt_parse_room_info HTTP_STATUS BODYFILE (pure; unit-tested)
pt_parse_room_info() {
    if ! grep -q '[^[:space:]]' "$2"; then PT_ERROR="INVALID_RESPONSE: empty response from room/info (http $1)"; return 1; fi
    pt_json_flatten "$2" || { PT_ERROR="INVALID_RESPONSE: room/info is not JSON (http $1)"; return 1; }
    _ri_sc=$(pt_jget status_code)
    case $_ri_sc in
        "" | 0) ;;
        4003110) PT_ERROR="AGE_RESTRICTED: 18+ room - pass session cookies (sessionid=...; sid_tt=...)"; return 1 ;;
        *) PT_ERROR="API_ERROR: status_code=$_ri_sc"; return 1 ;;
    esac
    grep -q "^data\." "$_PT_DIR/json.flat" || { PT_ERROR="INVALID_RESPONSE: missing 'data' in room info"; return 1; }
    PT_INFO_TITLE=$(pt_jget data.title)
    PT_INFO_VIEWERS=$(pt_jget data.user_count)
    PT_INFO_LIKES=$(pt_jget data.stats.like_count)
    PT_INFO_TOTAL=$(pt_jget data.stats.total_user)
    PT_INFO_OWNER_ID=$(pt_jget data.owner.id_str)
    PT_INFO_FLV_ORIGIN=""; PT_INFO_FLV_HD=""; PT_INFO_FLV_SD=""; PT_INFO_FLV_LD=""; PT_INFO_FLV_AO=""
    pt_jget data.stream_url.live_core_sdk_data.pull_data.stream_data | sed 's/\\\\/\\/g' > "$_PT_DIR/stream_data.json"
    if grep -q . "$_PT_DIR/stream_data.json"; then
        _pt_awk -f "$PT_LIB_DIR/pt_json.awk" < "$_PT_DIR/stream_data.json" > "$_PT_DIR/stream.flat" || { PT_ERROR="INVALID_RESPONSE: stream_data is not JSON"; return 1; }
        PT_INFO_FLV_ORIGIN=$(pt_jget data.origin.main.flv "$_PT_DIR/stream.flat")
        PT_INFO_FLV_HD=$(pt_jget data.hd.main.flv "$_PT_DIR/stream.flat")
        [ -z "$PT_INFO_FLV_HD" ] && PT_INFO_FLV_HD=$(pt_jget data.uhd.main.flv "$_PT_DIR/stream.flat")
        PT_INFO_FLV_SD=$(pt_jget data.sd.main.flv "$_PT_DIR/stream.flat")
        PT_INFO_FLV_LD=$(pt_jget data.ld.main.flv "$_PT_DIR/stream.flat")
        PT_INFO_FLV_AO=$(pt_jget data.ao.main.flv "$_PT_DIR/stream.flat")
    fi
    return 0
}

# pt_fetch_room_audience ROOM_ID ANCHOR_ID|"" COOKIES -> on_audience_viewer per named viewer; PT_AUD_TOTAL, PT_AUD_ANON
pt_fetch_room_audience() {
    _ra_anchor=$2
    if [ -z "$_ra_anchor" ]; then
        pt_fetch_room_info "$1" "$3" || return 1
        _ra_anchor=$PT_INFO_OWNER_ID
        [ -n "$_ra_anchor" ] || { PT_ERROR="INVALID_RESPONSE: no owner id in room info"; return 1; }
    fi
    pt_locale
    _ra_path="/webcast/ranklist/online_audience/?aid=1988&app_name=tiktok_web&device_platform=web_pc&app_language=$PT_LANG_EFFECTIVE&browser_language=$PT_LANG_EFFECTIVE-$PT_REGION_EFFECTIVE&channel=tiktok_web&room_id=$1&anchor_id=$_ra_anchor"
    pt_http_get "$PT_WEBCAST_HOST" "$PT_WEBCAST_PORT" "$_ra_path" "$3" || { PT_ERROR="HTTP: $PT_ERROR"; return 1; }
    pt_parse_audience "$PT_HTTP_STATUS" "$_PT_DIR/http.body"
}

# pt_parse_audience HTTP_STATUS BODYFILE (pure; unit-tested)
pt_parse_audience() {
    if ! grep -q '[^[:space:]]' "$2"; then PT_ERROR="INVALID_RESPONSE: empty response from online_audience (http $1)"; return 1; fi
    pt_json_flatten "$2" || { PT_ERROR="INVALID_RESPONSE: online_audience is not JSON"; return 1; }
    _pa_sc=$(pt_jget status_code)
    case $_pa_sc in
        0) ;;
        20003) PT_ERROR="SESSION_REQUIRED: audience roster needs login - pass session cookies"; return 1 ;;
        "") PT_ERROR="INVALID_RESPONSE: no status_code in online_audience response"; return 1 ;;
        *) PT_ERROR="INVALID_RESPONSE: online_audience status_code=$_pa_sc $(pt_jget data.message)"; return 1 ;;
    esac
    grep -q "^data\." "$_PT_DIR/json.flat" || { PT_ERROR="INVALID_RESPONSE: missing 'data' in online_audience"; return 1; }
    PT_AUD_TOTAL=$(pt_jget data.total); PT_AUD_ANON=$(pt_jget data.anonymous)
    _pt_awk -F "$PT_TAB" -f "$PT_LIB_DIR/pt_audience.awk" "$_PT_DIR/json.flat" > "$_PT_DIR/audience.tsv"
    while IFS=$_PT_US read -r _av_rank _av_score _av_id _av_user _av_nick _av_sec _av_av _av_fol _av_ver _av_isf _av_ifg _av_sub; do
        on_audience_viewer "$_av_rank" "$_av_score" "$_av_id" "$_av_user" "$_av_nick" "$_av_fol" "$_av_ver" "$_av_isf" "$_av_ifg" "$_av_sub" "$_av_sec" "$_av_av"
    done < "$_PT_DIR/audience.tsv"
    return 0
}

# pt_fetch_profile USERNAME -> PT_PROFILE_* (cached PT_PROFILE_TTL seconds in PT_CACHE_DIR, incl. private/not-found)
pt_fetch_profile() {
    _fp_user=$(echo "$1" | sed 's/^@//' | tr 'A-Z' 'a-z')
    mkdir -p "$PT_CACHE_DIR" || { PT_ERROR="CACHE: cannot create $PT_CACHE_DIR"; return 1; }
    _fp_file="$PT_CACHE_DIR/profile.$_fp_user"
    if [ -f "$_fp_file" ] && [ $(( $(date +%s) - $(head -n 1 "$_fp_file") )) -lt "$PT_PROFILE_TTL" ]; then
        PT_PROFILE_CACHED=1
        _pt_load_profile "$_fp_file"
        return $?
    fi
    PT_PROFILE_CACHED=0
    [ -n "$_PT_PROFILE_TTWID" ] || { pt_fetch_ttwid || return 1; _PT_PROFILE_TTWID=$PT_TTWID; }
    _fp_cookie="ttwid=$_PT_PROFILE_TTWID"; [ -n "$PT_COOKIES" ] && _fp_cookie="$_fp_cookie; $PT_COOKIES"
    pt_http_get "$PT_WEB_HOST" "$PT_WEB_PORT" "/@$_fp_user" "$_fp_cookie" || { PT_ERROR="HTTP: $PT_ERROR"; return 1; }
    pt_parse_profile "$_fp_user" "$_PT_DIR/http.body" || case $PT_ERROR in
        PROFILE_PRIVATE* | PROFILE_NOT_FOUND*) { date +%s; echo "ERR$PT_TAB$PT_ERROR"; } > "$_fp_file"; return 1 ;;
        *) return 1 ;;
    esac
    { date +%s; cat "$_PT_DIR/profile.tsv"; } > "$_fp_file"
    _pt_load_profile "$_fp_file"
}

_pt_load_profile() {
    if grep -q "^ERR$PT_TAB" "$1"; then PT_ERROR=$(grep "^ERR$PT_TAB" "$1" | cut -f2-); return 1; fi
    while IFS=$PT_TAB read -r _lp_k _lp_v; do
        case $_lp_k in [A-Z]*) eval "PT_PROFILE_$_lp_k=\$_lp_v" ;; esac
    done < "$1"
    return 0
}

# pt_parse_profile USERNAME HTMLFILE -> $_PT_DIR/profile.tsv (KEY<TAB>value) (pure; unit-tested)
pt_parse_profile() {
    _pt_awk 'BEGIN { m = "id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\"" } { s = s $0 "\n" } END {
        i = index(s, m); if (!i) exit 1; s = substr(s, i); i = index(s, ">"); s = substr(s, i + 1)
        j = index(s, "</script>"); if (!j) exit 1; printf "%s", substr(s, 1, j - 1) }' "$2" > "$_PT_DIR/sigi.json" ||
        { PT_ERROR="PROFILE_SCRAPE: SIGI script tag not found"; return 1; }
    pt_json_flatten "$_PT_DIR/sigi.json" || { PT_ERROR="PROFILE_SCRAPE: SIGI blob is not JSON"; return 1; }
    _pp_p="__DEFAULT_SCOPE__.webapp.user-detail"
    _pp_sc=$(pt_jget "$_pp_p.statusCode")
    case $_pp_sc in
        0) ;;
        10222) PT_ERROR="PROFILE_PRIVATE: @$1"; return 1 ;;
        10221 | 10223) PT_ERROR="PROFILE_NOT_FOUND: @$1"; return 1 ;;
        "") PT_ERROR="PROFILE_SCRAPE: missing $_pp_p"; return 1 ;;
        *) PT_ERROR="PROFILE_ERROR: statusCode=$_pp_sc"; return 1 ;;
    esac
    _pt_awk -F "$PT_TAB" -v p="$_pp_p.userInfo." -f "$PT_LIB_DIR/pt_profile.awk" "$_PT_DIR/json.flat" > "$_PT_DIR/profile.tsv"
}
