#!/bin/sh
# stream_info.sh USER [COOKIES] - room metadata + FLV URLs (cookies only needed for 18+ rooms)
. "${PT_LIB_DIR:-$(dirname "$0")/../lib}/piratetok.sh"
pt_resolve_room "$1"
[ "$PT_ONLINE" = LIVE ] || { echo "$PT_ERROR" >&2; exit 1; }
if pt_fetch_room_info "$PT_ROOM_ID" "$2"; then
    echo "title:   $PT_INFO_TITLE"
    echo "viewers: $PT_INFO_VIEWERS (total $PT_INFO_TOTAL), likes: $PT_INFO_LIKES"
    echo "flv:     origin=$PT_INFO_FLV_ORIGIN"
    echo "         hd=$PT_INFO_FLV_HD sd=$PT_INFO_FLV_SD ld=$PT_INFO_FLV_LD ao=$PT_INFO_FLV_AO"
else
    echo "$PT_ERROR" >&2; exit 1
fi
