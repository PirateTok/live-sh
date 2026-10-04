# pt_audience.awk - flattened online_audience JSON -> one \037-separated row per named viewer:
# rank score user_id username nickname sec_uid avatar_url follower_count verified is_follower is_following is_subscriber
$1 ~ /^data\.ranks\.[0-9]+\./ {
    split($1, p, ".")
    i = p[3]; if (i + 1 > n) n = i + 1
    k = substr($1, length("data.ranks." i ".") + 1)
    V[i, k] = $2
}
function b(v) { return v == "true" ? 1 : 0 }
END {
    for (i = 0; i < n; i++) {
        if (!((i, "user.nickname") in V) && !((i, "user.id_str") in V) && !((i, "user.id") in V)) continue
        id = V[i, "user.id_str"]; if (id == "") id = V[i, "user.id"]
        printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%d\037%d\037%d\037%d\n", V[i, "rank"] + 0, V[i, "score"] + 0, id, V[i, "user.display_id"], V[i, "user.nickname"], \
            V[i, "user.sec_uid"], V[i, "user.avatar_thumb.url_list.0"], V[i, "user.follow_info.follower_count"] + 0, \
            b(V[i, "user.verified"]), b(V[i, "user.is_follower"]), b(V[i, "user.is_following"]), b(V[i, "user.is_subscribe"])
    }
}
