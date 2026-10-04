#!/bin/sh
# profile_lookup.sh USER... - profile + HD avatars; second lookup is served from PT_CACHE_DIR
. "${PT_LIB_DIR:-$(dirname "$0")/../lib}/piratetok.sh"
for round in fetch cache; do
    for u in "$@"; do
        if pt_fetch_profile "$u"; then
            printf '[%s] @%s %s - %s followers, avatar %s\n' "$round" "$PT_PROFILE_UNIQUE_ID" "$PT_PROFILE_NICKNAME" "$PT_PROFILE_FOLLOWER_COUNT" "$PT_PROFILE_AVATAR_LARGE"
        else
            printf '[%s] @%s %s\n' "$round" "$u" "$PT_ERROR"
        fi
    done
done
