#!/bin/sh
# Offline wire tests against local TLS fakes (tests/fixtures.py; python3 is a test-only dependency):
# F2/F3/F4/F5/F7/F8/F19 end-to-end client, F6 authenticated CONNECT proxy, F16 profile cache, TLS verification.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PT_LIB_DIR=$ROOT/lib
. "$ROOT/lib/piratetok.sh"
_pt_tmp
W=$(mktemp -d "${TMPDIR:-/tmp}/ptwire.XXXXXX")
PIDS=""
PASS=0
FAIL=0
eq() { if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "ok   $1"; else FAIL=$((FAIL + 1)); echo "FAIL $1: got [$2] want [$3]"; fi; }
has() { case $2 in *"$3"*) eq "$1" x x ;; *) eq "$1" "$2" "*$3*" ;; esac; }
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$W" "$_PT_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# test CA + server cert for 127.0.0.1, and a rogue self-signed cert
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=pt-test-ca -keyout "$W/ca.key" -out "$W/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj /CN=127.0.0.1 -keyout "$W/srv.key" -out "$W/srv.csr" 2>/dev/null
printf 'subjectAltName=IP:127.0.0.1\n' > "$W/san.ext"
openssl x509 -req -in "$W/srv.csr" -CA "$W/ca.pem" -CAkey "$W/ca.key" -CAcreateserial -days 2 -extfile "$W/san.ext" -out "$W/srv.pem" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 -keyout "$W/rogue.key" -out "$W/rogue.pem" 2>/dev/null

# start VAR NAME fixture-args... : launch a fixture, wait for its port, set VAR=port (no subshell)
start() {
    _sv=$1; _sn=$2; shift 2
    python3 "$ROOT/tests/fixtures.py" "$@" &
    PIDS="$PIDS $!"
    while [ ! -f "$W/$_sn.port" ]; do sleep 0.1; done
    eval "$_sv=\$(cat \"\$W/\$_sn.port\")"
}

PT_CAFILE=$W/ca.pem
PT_WEB_HOST=127.0.0.1 PT_WEBCAST_HOST=127.0.0.1 PT_CDN=127.0.0.1
PT_TTWID_DELAY=0.05

# --- TLS verification ---
start ROGUE rogue origin "$W/rogue.pem" "$W/rogue.key" "$W/rogue.port" "$W/rogue.log"
PT_WEB_PORT=$ROGUE
pt_fetch_ttwid; eq "TLS: rogue cert rejected with test CA (no request served)" "$?:$(cat "$W/rogue.log" 2>/dev/null | grep -c '^/')" "2:0"
PT_CAFILE="" pt_fetch_ttwid; eq "TLS: rogue cert rejected by system trust store" "$?" 2

# --- F19/F5 ttwid retry against a real local responder ---
start O3 o3 origin "$W/srv.pem" "$W/srv.key" "$W/o3.port" "$W/o3.log" 3
PT_WEB_PORT=$O3
pt_fetch_ttwid; eq "F19 ttwid: 3 misses then cookie (valid CA-signed cert)" "$?:$PT_TTWID:$(grep -c '^/	' "$W/o3.log")" "0:tok0:4"
start O99 o99 origin "$W/srv.pem" "$W/srv.key" "$W/o99.port" "$W/o99.log" 99
PT_WEB_PORT=$O99
pt_fetch_ttwid; eq "F19 ttwid: never set -> error after 8 requests" "$?:$(grep -c '^/	' "$W/o99.log")" "1:8"
has "F19 ttwid: error kind" "$PT_ERROR" "INVALID_RESPONSE: no ttwid cookie after 8 attempts"
PT_WEB_PORT=1; _t0=$(date +%s); pt_fetch_ttwid; eq "F19 ttwid: transport error, no retry" "$?:$(( $(date +%s) - _t0 < 2 ))" "2:1"

# --- end-to-end client (F2/F3/F4/F5/F7/F8) ---
start OR or origin "$W/srv.pem" "$W/srv.key" "$W/or.port" "$W/or.log" 0
start WS ws ws "$W/srv.pem" "$W/srv.key" "$W/ws.port" "$W/ws.log"
LOG=""
on_connected() { LOG="$LOG connected=$1"; }
on_chat() { LOG="$LOG chat=$1|$2"; }
on_reconnecting() { LOG="$LOG reconnecting=$1/$2/$3"; }
on_disconnected() { LOG="$LOG disconnected"; }
PT_WEB_PORT=$OR PT_WEBCAST_PORT=$OR PT_WS_PORT=$WS PT_MAX_RETRIES=2 PT_HEARTBEAT_SEC=7 PT_LANGUAGE=ro PT_REGION=RO PT_COMPRESS=0
PT_UA="UA-Test/1" PT_COOKIES="sessionid=abc; sid_tt=def"
pt_connect someone
eq "F4/F5 lifecycle: chat, reconnect budget, DEVICE_BLOCKED, disconnected" "$LOG" \
    " connected=7001 chat=Ana (@ana)|salut reconnecting=1/2/2 reconnecting=2/2/2 disconnected"
eq "F5 ttwid reused across close, rotated after DEVICE_BLOCKED" "$(cut -f2 "$W/ws.log" | grep '^cookie=' | sed 's/; sessionid.*//' | tr '\n' ' ')" \
    "cookie=ttwid=tok0 cookie=ttwid=tok0 cookie=ttwid=tok1 "
eq "F5 two ttwid fetches (initial + rotation)" "$(grep -c '^/	' "$W/or.log")" 2
eq "F2 heartbeat then enter_room with room id" "$(grep '^frame' "$W/ws.log" | tr '\t' ' ' | tr '\n' ' ')" "frame hb room_id=7001 frame im_enter_room room_id=7001 "
eq "F2 needs_ack -> ack with log_id + exact internal_ext" "$(grep '^ack' "$W/ws.log" | tr '\t' ' ')" "ack log_id=77 ext_ok=True"
_c0=$(grep '^conn0' "$W/ws.log")
has "F7 fixed UA on WSS" "$_c0" "ua=UA-Test/1"
has "F7 session cookies appended on WSS" "$_c0" "sessionid=abc; sid_tt=def"
has "F8 Accept-Language from language/region" "$_c0" "lang=ro-RO,ro;q=0.9"
for _p in heartbeat_duration=7000 browser_language=ro-RO webcast_language=ro "compress=&" room_id=7001; do has "F3/F8 WSS url $_p" "$_c0" "$_p"; done
has "F7 fixed UA on HTTP too" "$(grep '^/api-live' "$W/or.log")" "ua=UA-Test/1"

# --- F6 authenticated HTTP CONNECT proxy for HTTP + WSS ---
start PX px proxy "$W/px.port" "$W/px.log" user 's3cret'
start WS2 ws2 ws "$W/srv.pem" "$W/srv.key" "$W/ws2.port" "$W/ws2.log"
LOG=""
PT_PROXY="http://user:s3cret@127.0.0.1:$PX" PT_MAX_RETRIES=0 PT_WS_PORT=$WS2
pt_connect someone
has "F6 client works through the proxy" "$LOG" "chat=Ana (@ana)|salut"
eq "F6 room + ttwid + WSS all tunneled with Basic auth" "$(sort "$W/px.log" | uniq -c | awk '{ print $1, $2, $3, $4 }' | sort | tr '\n' ' ')" \
    "$(printf '1 CONNECT 127.0.0.1:%s auth=ok\n2 CONNECT 127.0.0.1:%s auth=ok\n' "$WS2" "$OR" | sort | tr '\n' ' ')"
has "F2 ack also through the proxy tunnel" "$(cat "$W/ws2.log")" "ext_ok=True"
PT_PROXY="http://user:wrong@127.0.0.1:$PX"
pt_resolve_room someone; eq "F6 wrong proxy credentials fail" "$PT_ONLINE" ERROR
has "F6 proxy log shows rejected auth" "$(tail -n 1 "$W/px.log")" "auth=bad"
PT_PROXY="socks5://127.0.0.1:$PX"
pt_resolve_room someone; has "F6 socks is rejected (documented limit)" "$PT_ERROR" "no SOCKS"
PT_PROXY=""

# --- F16 profile cache against the local origin ---
PT_WEB_PORT=$OR PT_CACHE_DIR="$W/cache"
pt_fetch_profile Alice; eq "F16 profile fetched" "$?:$PT_PROFILE_CACHED:$PT_PROFILE_NICKNAME:$PT_PROFILE_FOLLOWER_COUNT" "0:0:Alice:10"
pt_fetch_profile @alice; eq "F16 second fetch from cache" "$?:$PT_PROFILE_CACHED:$(grep -c '^/@alice' "$W/or.log")" "0:1:1"
pt_fetch_profile ghost; pt_fetch_profile ghost; eq "F16 not-found negatively cached" "$?:$PT_ERROR:$(grep -c '^/@ghost' "$W/or.log")" "1:PROFILE_NOT_FOUND: @ghost:1"
pt_fetch_profile priv; pt_fetch_profile priv; eq "F16 private negatively cached" "$PT_ERROR:$(grep -c '^/@priv' "$W/or.log")" "PROFILE_PRIVATE: @priv:1"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
