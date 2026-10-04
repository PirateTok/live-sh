#!/bin/sh
# Static gate: dash -n on every script (+ examples, F17), awk programs parse under busybox awk,
# R1 file size limit (800 LOC). usage: sh tests/check.sh
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAIL=0
for f in "$ROOT"/tiktok-live.sh "$ROOT"/package.sh "$ROOT"/lib/*.sh "$ROOT"/examples/*.sh "$ROOT"/tests/*.sh "$ROOT"/tools/*.sh; do
    if dash -n "$f"; then echo "ok   syntax ${f#$ROOT/}"; else echo "FAIL syntax ${f#$ROOT/}"; FAIL=1; fi
done
for f in "$ROOT"/lib/*.awk; do
    if echo '{}' | LC_ALL=C busybox awk -v schema="$ROOT/lib/piratetok.proto" -v events="$ROOT/lib/pt_events.tsv" -v mode=msg -f "$f" >/dev/null 2>"$ROOT/.awkcheck"; then
        echo "ok   busybox awk ${f#$ROOT/}"
    else echo "FAIL busybox awk ${f#$ROOT/}: $(head -n 1 "$ROOT/.awkcheck")"; FAIL=1; fi
    rm -f "$ROOT/.awkcheck"
done
for f in "$ROOT"/lib/* "$ROOT"/tests/* "$ROOT"/examples/* "$ROOT"/tiktok-live.sh; do
    n=$(wc -l < "$f")
    [ "$n" -gt 800 ] && { echo "FAIL R1 ${f#$ROOT/} has $n lines"; FAIL=1; }
done
grep -rln 'piratetok\.boat' "$ROOT" --exclude-dir=.git --exclude-dir=testdata --exclude=check.sh && { echo "FAIL old domain still referenced"; FAIL=1; }
[ "$FAIL" -eq 0 ] && echo "--- check passed ---"
exit "$FAIL"
