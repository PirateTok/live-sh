# pt_json.awk - flatten JSON (stdin) into "path<TAB>value" lines (POSIX awk, run with LC_ALL=C).
# Objects join keys with '.', arrays use 0-based indexes (data.ranks.0.user.nickname).
# Strings are unescaped (\uXXXX -> UTF-8); output escapes \\ \t \n \r. Numbers keep their text.
# A malformed document prints "ERROR<TAB>message" and exits 2.

BEGIN { for (i = 0; i < 16; i++) HX[substr("0123456789abcdef", i + 1, 1)] = i; for (i = 0; i < 6; i++) HX[substr("ABCDEF", i + 1, 1)] = 10 + i }
{ S = S $0 "\n" }
END {
    N = length(S); I = 1
    ws()
    if (I > N) fail("empty document")
    value("")
    ws()
    if (I <= N) fail("trailing data at " I)
}

function fail(msg) { printf "ERROR\t%s\n", msg; exit 2 }
function ws(c) { while (I <= N) { c = substr(S, I, 1); if (c == " " || c == "\t" || c == "\n" || c == "\r") I++; else break } }
function key(path, k) { return path == "" ? k : path "." k }
function out(path, v) { gsub(/\\/, "\\\\", v); gsub(/\t/, "\\t", v); gsub(/\n/, "\\n", v); gsub(/\r/, "\\r", v); printf "%s\t%s\n", path, v }

function value(path,    c, t) {
    ws()
    c = substr(S, I, 1)
    if (c == "{") object(path)
    else if (c == "[") array(path)
    else if (c == "\"") out(path, string())
    else {
        t = ""
        while (I <= N) { c = substr(S, I, 1); if (c ~ /[-+0-9.eEtrufalsn]/) { t = t c; I++ } else break }
        if (t == "") fail("unexpected '" c "' at " I)
        out(path, t)
    }
}

function object(path,    k) {
    I++; ws()
    if (substr(S, I, 1) == "}") { I++; return }
    while (1) {
        ws()
        if (substr(S, I, 1) != "\"") fail("expected key at " I)
        k = string(); ws()
        if (substr(S, I, 1) != ":") fail("expected ':' at " I)
        I++
        value(key(path, k)); ws()
        c = substr(S, I, 1); I++
        if (c == "}") return
        if (c != ",") fail("expected ',' or '}' at " I)
    }
}

function array(path,    n, c) {
    I++; ws(); n = 0
    if (substr(S, I, 1) == "]") { I++; return }
    while (1) {
        value(key(path, n++)); ws()
        c = substr(S, I, 1); I++
        if (c == "]") return
        if (c != ",") fail("expected ',' or ']' at " I)
    }
}

function string(    r, c, cp, lo) {
    I++; r = ""
    while (I <= N) {
        c = substr(S, I, 1); I++
        if (c == "\"") return r
        if (c != "\\") { r = r c; continue }
        c = substr(S, I, 1); I++
        if (c == "n") r = r "\n"
        else if (c == "t") r = r "\t"
        else if (c == "r") r = r "\r"
        else if (c == "b") r = r "\b"
        else if (c == "f") r = r "\f"
        else if (c == "u") {
            cp = hex4(); I += 4
            if (cp >= 55296 && cp < 56320 && substr(S, I, 2) == "\\u") { I += 2; lo = hex4(); I += 4; cp = 65536 + (cp - 55296) * 1024 + (lo - 56320) }
            r = r utf8(cp)
        } else r = r c
    }
    fail("unterminated string")
}

function hex4(    i, v) { v = 0; for (i = 0; i < 4; i++) v = v * 16 + HX[substr(S, I + i, 1)]; return v }

function utf8(cp) {
    if (cp < 128) return sprintf("%c", cp)
    if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
    if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
    return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
}
