# pt_profile.awk - flattened SIGI user-detail -> KEY<TAB>value lines (keys become PT_PROFILE_<KEY>)
BEGIN {
    m["user.id"] = "USER_ID"; m["user.uniqueId"] = "UNIQUE_ID"; m["user.nickname"] = "NICKNAME"; m["user.signature"] = "BIO"
    m["user.avatarThumb"] = "AVATAR_THUMB"; m["user.avatarMedium"] = "AVATAR_MEDIUM"; m["user.avatarLarger"] = "AVATAR_LARGE"
    m["user.verified"] = "VERIFIED"; m["user.privateAccount"] = "PRIVATE_ACCOUNT"; m["user.isOrganization"] = "IS_ORGANIZATION"
    m["user.roomId"] = "ROOM_ID"; m["user.bioLink.link"] = "BIO_LINK"
    m["stats.followerCount"] = "FOLLOWER_COUNT"; m["stats.followingCount"] = "FOLLOWING_COUNT"; m["stats.heartCount"] = "HEART_COUNT"
    m["stats.videoCount"] = "VIDEO_COUNT"; m["stats.friendCount"] = "FRIEND_COUNT"
    for (k in m) seen[m[k]] = ""
}
index($1, p) == 1 { k = substr($1, length(p) + 1); if (k in m) seen[m[k]] = $2 }
END { for (k in seen) printf "%s\t%s\n", k, seen[k] }
