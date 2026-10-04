#!/bin/sh
# Replay live-testdata captures through the sh decoder + helpers and compare with the manifests.
# Testdata: $PIRATETOK_TESTDATA, else ./testdata (captures/ + manifests/ or captures/manifests/). Missing data FAILS.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PT_LIB_DIR=$ROOT/lib
. "$ROOT/lib/piratetok.sh"
_pt_tmp
TD=${PIRATETOK_TESTDATA:-$ROOT/testdata}
PASS=0
FAIL=0

manifest_for() {
    for _m in "$TD/manifests/$1.json" "$TD/captures/manifests/$1.json"; do [ -f "$_m" ] && { echo "$_m"; return; }; done
}

on_event() {
    case $1 in
        Like) pt_like_accumulate; pt_get count total
              [ "$PT_LIKE_BACKWARDS" = 1 ] && _bw=true || _bw=false
              echo "$_g1 $_g2 $PT_LIKE_TOTAL $PT_LIKE_ACCUMULATED $_bw" >> "$OUT/likes" ;;
        Gift) pt_gift_streak; pt_get gift_id repeat_count
              [ "$PT_STREAK_FINAL" = 1 ] && _fin=true || _fin=false
              eval "_n=\${_GN_$PT_STREAK_ID:-0}"; eval "_GN_$PT_STREAK_ID=$((_n + 1))"
              echo "$PT_STREAK_ID $_n $_g1 $_g2 $PT_STREAK_EVENT_COUNT $_fin $PT_STREAK_TOTAL_DIAMONDS" >> "$OUT/gifts" ;;
        Unknown) echo "$PT_EV_METHOD" >> "$OUT/unknown" ;;
    esac
    echo "$1" >> "$OUT/types"
}

check() {
    capture=$1 name=$2
    bin="$TD/captures/$capture.bin"
    man=$(manifest_for "$name")
    if [ ! -f "$bin" ] || [ -z "$man" ]; then FAIL=$((FAIL + 1)); echo "FAIL $capture: testdata missing ($bin / $name.json)"; return; fi
    echo "LOAD $capture <- $bin + $man"
    OUT="$_PT_DIR/$capture"; rm -rf "$OUT"; mkdir -p "$OUT"; : > "$OUT/likes"; : > "$OUT/gifts"; : > "$OUT/unknown"; : > "$OUT/types"
    pt_like_reset
    for _v in $(set | sed -n 's/^\(_PT_GS_[0-9]*\)=.*/\1/p; s/^\(_GN_[0-9]*\)=.*/\1/p'); do unset "$_v"; done
    sh "$ROOT/tests/decode_capture.sh" "$bin" > "$OUT/events"
    pt_dispatch_file "$OUT/events"
    LC_ALL=C awk -f "$PT_LIB_DIR/pt_json.awk" < "$man" > "$OUT/man.flat"

    exp() { LC_ALL=C awk -F "$PT_TAB" -v p="$1" 'index($1, p) == 1 { print substr($1, length(p) + 1) " " $2 }' "$OUT/man.flat" | sort; }
    got_types=$(sort "$OUT/types" | uniq -c | awk '{ print $2 " " $1 }' | sort)
    cmp_one "$capture event_types" "$got_types" "$(exp event_types.)"
    cmp_one "$capture unknown_types" "$(sort "$OUT/unknown" | uniq -c | awk '{ print $2 " " $1 }' | sort)" "$(exp unknown_types.)"
    cmp_one "$capture sub_routed" "follow $(grep -cx Follow "$OUT/types") join $(grep -cx Join "$OUT/types") live_ended $(grep -cx LiveEnded "$OUT/types") share $(grep -cx Share "$OUT/types")" \
        "$(exp sub_routed. | tr '\n' ' ' | sed 's/ $//')"
    cmp_one "$capture event_count" "$(wc -l < "$OUT/types" | tr -d ' ')" "$(LC_ALL=C awk -F "$PT_TAB" '$1 == "event_count" { print $2 }' "$OUT/man.flat")"
    like_exp=$(LC_ALL=C awk -F "$PT_TAB" '$1 ~ /^like_accumulator\.events\./ { split($1, p, "."); V[p[3], p[4]] = $2; if (p[3] + 1 > n) n = p[3] + 1 }
        END { for (i = 0; i < n; i++) print V[i, "wire_count"], V[i, "wire_total"], V[i, "acc_total"], V[i, "accumulated"], V[i, "went_backwards"] }' "$OUT/man.flat")
    cmp_one "$capture like_accumulator ($(wc -l < "$OUT/likes" | tr -d ' ') events)" "$(cat "$OUT/likes")" "$like_exp"
    gift_exp=$(LC_ALL=C awk -F "$PT_TAB" '$1 ~ /^gift_streaks\.groups\./ { n = split($1, p, "."); V[p[3] " " p[4], p[5]] = $2; K[p[3] " " p[4]] = 1 }
        END { for (k in K) print k, V[k, "gift_id"], V[k, "repeat_count"], V[k, "delta"], V[k, "is_final"], V[k, "diamond_total"] }' "$OUT/man.flat" | sort)
    cmp_one "$capture gift_streaks ($(wc -l < "$OUT/gifts" | tr -d ' ') events)" "$(sort "$OUT/gifts")" "$gift_exp"
}

cmp_one() {
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "ok   $1"; else
        FAIL=$((FAIL + 1)); echo "FAIL $1"; printf '%s\n' "$2" > "$_PT_DIR/got"; printf '%s\n' "$3" > "$_PT_DIR/want"; diff "$_PT_DIR/want" "$_PT_DIR/got" | head -5
    fi
}

for c in calvinterest6 happyhappygaltv fox4newsdallasfortworth; do
    check "$c" "$c"
    check "${c}_raw" "$c"
done
rm -rf "$_PT_DIR"
echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
