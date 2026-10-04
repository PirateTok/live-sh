#!/bin/sh
# online_check.sh USER... - LIVE / OFF / 404 / APIERROR / BLOCKED per user (no WebSocket)
. "${PT_LIB_DIR:-$(dirname "$0")/../lib}/piratetok.sh"
for u in "$@"; do
    r=$(pt_check_online "$u")
    case $r in
        LIVE:*) r=${r#LIVE:}; printf '  LIVE  @%s  room=%s anchor=%s\n' "$u" "${r%%:*}" "${r#*:}" ;;
        *) pt_resolve_room "$u"; printf '  %-5s @%s  %s\n' "$PT_ONLINE" "$u" "$PT_ERROR" ;;
    esac
done
