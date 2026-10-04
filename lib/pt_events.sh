# pt_events.sh - event dispatch + field access. Sourced by piratetok.sh.
# Inside handlers: PT_EVENT (Chat, Gift, ..., Unknown), PT_EV_METHOD (wire method), PT_EV_FIELDS
# ("path<TAB>value" lines, see pt_proto.awk), pt_field PATH, pt_get PATH... (-> $_g1..$_g9).

_PT_US=$(printf '\037')

pt_field() { printf '%s' "$PT_EV_FIELDS" | LC_ALL=C awk -F "$PT_TAB" -v p="$1" '$1 == p { print $2; exit }'; }

# pt_get PATH... -> _g1.._g9 (empty when absent), one awk call
pt_get() {
    _pg=$(printf '%s' "$PT_EV_FIELDS" | LC_ALL=C awk -F "$PT_TAB" -v want="$*" -v us="$_PT_US" '
        BEGIN { n = split(want, w, " ") } { v[$1] = $2 }
        END { for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? us : ""), v[w[i]]; print "" }')
    IFS=$_PT_US read -r _g1 _g2 _g3 _g4 _g5 _g6 _g7 _g8 _g9 <<EOF
$_pg
EOF
}

# pt_user_label [PREFIX] -> "nickname (@unique_id)" for the event's user
pt_user_label() {
    pt_get "${1:-user}.nickname" "${1:-user}.unique_id"
    printf '%s%s\n' "${_g1:-?}" "${_g2:+ (@$_g2)}"
}

# pt_top_viewers -> "rank score nickname unique_id user_id" (\037-separated) for RoomUserSeq, sorted by rank,
# entries without a decoded user skipped (same as live-rs top_viewers())
pt_top_viewers() {
    printf '%s' "$PT_EV_FIELDS" | LC_ALL=C awk -F "$PT_TAB" '
        $1 ~ /^ranks_list\.[0-9]+\./ { split($1, p, "."); i = p[2]; if (i + 1 > n) n = i + 1; V[i, substr($1, length("ranks_list." i ".") + 1)] = $2 }
        END { for (i = 0; i < n; i++) if ((i, "user.nickname") in V || (i, "user.id") in V)
                  printf "%d\037%d\037%s\037%s\037%s\n", V[i, "rank"], V[i, "score"], V[i, "user.nickname"], V[i, "user.unique_id"], V[i, "user.id"] }' |
        sort -t "$_PT_US" -k1,1n
}

pt_dispatch_file() {
    PT_EV_FIELDS=""
    while IFS= read -r _dl; do
        case $_dl in
            E"$PT_TAB"*) _de=${_dl#E"$PT_TAB"}; PT_EVENT=${_de%%"$PT_TAB"*}; PT_EV_METHOD=${_de#*"$PT_TAB"}; PT_EV_FIELDS="" ;;
            F"$PT_TAB"*) PT_EV_FIELDS="$PT_EV_FIELDS${_dl#F"$PT_TAB"}
" ;;
            Z) _pt_dispatch ;;
        esac
    done < "$1"
}

_pt_dispatch() {
    on_event "$PT_EVENT" "$PT_EV_METHOD"
    case $PT_EVENT in
        Chat) pt_get comment; on_chat "$(pt_user_label)" "$_g1" ;;
        Gift) pt_get gift_details.name repeat_count gift_details.diamond_count; on_gift "$(pt_user_label)" "${_g1:-gift}" "${_g2:-1}" "${_g3:-0}" ;;
        Like) pt_get total; on_like "$(pt_user_label)" "$_g1" ;;
        Join) on_join "$(pt_user_label)" ;;
        Follow) on_follow "$(pt_user_label)" ;;
        Share) on_share "$(pt_user_label)" ;;
        LiveEnded) on_ended ;;
        Unknown) pt_get payload; on_unknown "$PT_EV_METHOD" "$_g1" ;;
        RoomUserSeq)
            pt_get viewer_count
            on_viewers "$_g1"
            pt_top_viewers > "$_PT_DIR/top"
            while IFS=$_PT_US read -r _tv_rank _tv_score _tv_nick _tv_uid _tv_id; do
                on_top_viewer "$_tv_rank" "$_tv_score" "$_tv_nick" "$_tv_uid" "$_tv_id"
            done < "$_PT_DIR/top"
            ;;
    esac
}
