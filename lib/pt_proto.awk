# pt_proto.awk - schema-driven protobuf decoder in POSIX awk (run with LC_ALL=C).
# Input: one line of lowercase hex. Variables:
#   schema=PATH (piratetok.proto)   events=PATH (pt_events.tsv: method TAB Event TAB MessageType)
#   mode=frame     -> "payload_type<TAB>log_id<TAB>payload_hex"
#   mode=response  -> "A<TAB>needs_ack<TAB>internal_ext_hex", then per event:
#                     "E<TAB>Event<TAB>method", "F<TAB>path<TAB>value"..., "Z"
#   mode=msg type=MessageName -> "F<TAB>path<TAB>value" lines
# Paths: field names joined by '.', repeated fields get a 0-based index (ranks_list.0.rank).
# Strings escape \\ \t \n \r; bytes and unknown payloads are hex. int64 values stay exact.

BEGIN {
    for (i = 0; i < 256; i++) { h = sprintf("%02x", i); HEXV[h] = i; HEXS[i] = h }
    load_schema(schema)
    if (events != "") load_events(events)
}

function load_schema(path,    line, msg, open) {
    msg = ""
    while ((getline line < path) > 0) {
        sub(/\/\/.*/, "", line)
        if (match(line, /^[ \t]*message[ \t]+[A-Za-z0-9_]+/)) {
            msg = substr(line, RSTART, RLENGTH)
            sub(/^[ \t]*message[ \t]+/, "", msg)
            MSG[msg] = 1
            open = index(line, "{")
            if (open && index(line, "}")) { parse_fields(msg, substr(line, open + 1)); msg = "" }
            continue
        }
        if (msg == "") continue
        if (line ~ /^[ \t]*}/) { msg = ""; continue }
        parse_fields(msg, line)
    }
    close(path)
}

function parse_fields(msg, text,    n, stmts, i, s, tok, nt, k) {
    n = split(text, stmts, ";")
    for (i = 1; i <= n; i++) {
        s = stmts[i]
        gsub(/[{}]/, " ", s)
        if (s ~ /map</) continue
        gsub(/=/, " = ", s)
        nt = split(s, tok, " ")
        k = 1
        if (tok[1] == "repeated") k = 2
        if (nt < k + 3 || tok[k + 2] != "=") continue
        FT[msg, tok[k + 3]] = tok[k]
        FN[msg, tok[k + 3]] = tok[k + 1]
        FR[msg, tok[k + 3]] = (k == 2)
    }
}

function load_events(path,    line, f) {
    while ((getline line < path) > 0) {
        if (line ~ /^#/ || line == "") continue
        split(line, f, "\t")
        EVN[f[1]] = f[2]
        EVT[f[1]] = f[3]
    }
    close(path)
}

function load_bytes(hex,    i, n) {
    n = int(length(hex) / 2)
    for (i = 0; i < n; i++) B[i] = HEXV[substr(hex, 2 * i + 1, 2)]
    NB = n
}

function bmuladd(s, m, a,    i, d, carry, out) {
    carry = a
    out = ""
    for (i = length(s); i >= 1; i--) {
        d = substr(s, i, 1) * m + carry
        out = (d % 10) out
        carry = int(d / 10)
    }
    while (carry > 0) { out = (carry % 10) out; carry = int(carry / 10) }
    sub(/^0+/, "", out)
    return out == "" ? "0" : out
}

function bsub(a, b,    i, j, d, borrow, out) {
    out = ""
    borrow = 0
    j = length(b)
    for (i = length(a); i >= 1; i--) {
        d = substr(a, i, 1) - borrow - (j >= 1 ? substr(b, j, 1) : 0)
        j--
        if (d < 0) { d += 10; borrow = 1 } else borrow = 0
        out = d out
    }
    sub(/^0+/, "", out)
    return out == "" ? "0" : out
}

# varint at P as an exact decimal string; advances P
function varint(    n, i, v, g) {
    n = 0
    while (P < NB) { g = B[P]; VG[n++] = g % 128; P++; if (g < 128) break }
    if (n <= 7) {
        v = 0
        for (i = n - 1; i >= 0; i--) v = v * 128 + VG[i]
        return sprintf("%.0f", v)
    }
    v = "0"
    for (i = n - 1; i >= 0; i--) v = bmuladd(v, 128, VG[i])
    return v
}

function signed(v, typ) {
    if ((typ == "int64" || typ == "int32") && length(v) >= 19 && (length(v) > 19 || v > "9223372036854775807"))
        return "-" bsub("18446744073709551616", v)
    return v
}

function text(s, e,    i, b, out) {
    out = ""
    for (i = s; i < e; i++) {
        b = B[i]
        if (b == 92) out = out "\\\\"
        else if (b == 9) out = out "\\t"
        else if (b == 10) out = out "\\n"
        else if (b == 13) out = out "\\r"
        else if (b == 0) out = out "\\0"
        else out = out sprintf("%c", b)
    }
    return out
}

function hexs(s, e,    i, out) {
    out = ""
    for (i = s; i < e; i++) out = out HEXS[B[i]]
    return out
}

function emit(path, value) {
    BUF = BUF "F\t" path "\t" value "\n"
    FIELD[path] = value
}

function child(prefix, type, f, name,    key) {
    key = (prefix == "" ? name : prefix "." name)
    if (FR[type, f]) { key = key "." (CNT[key] + 0); CNT[(prefix == "" ? name : prefix "." name)]++ }
    return key
}

function decode(type, s, e, prefix,    tag, f, w, len, se, typ, name, v) {
    P = s
    while (P < e) {
        tag = varint() + 0
        f = int(tag / 8)
        w = tag % 8
        if (f == 0) { P = e; return }
        typ = FT[type, f]
        name = FN[type, f]
        if (w == 0) {
            v = varint()
            if (name != "" && !(typ in MSG)) emit(child(prefix, type, f, name), typ == "bool" ? (v != "0") : signed(v, typ))
        } else if (w == 2) {
            len = varint() + 0
            se = P + len
            if (name != "") {
                if (typ in MSG) decode(typ, P, se, child(prefix, type, f, name))
                else if (typ == "string") emit(child(prefix, type, f, name), text(P, se))
                else emit(child(prefix, type, f, name), hexs(P, se))
            }
            P = se
        } else if (w == 1) P += 8
        else if (w == 5) P += 4
        else { P = e; return }
    }
}

function event_block(name, method) {
    printf "E\t%s\t%s\n%sZ\n", name, method, BUF
}

function emit_event(method, s, e,    name, type, action) {
    if (!(method in EVN)) {
        printf "E\tUnknown\t%s\nF\tpayload\t%s\nZ\n", method, hexs(s, e)
        return
    }
    name = EVN[method]
    type = EVT[method]
    BUF = ""
    split("", FIELD)
    split("", CNT)
    if (type in MSG) decode(type, s, e, "")
    event_block(name, method)
    action = FIELD["action"]
    if (name == "Social" && action == "1") event_block("Follow", method)
    if (name == "Social" && (action == "3" || action == "4")) event_block("Share", method)
    if (name == "Member" && action == "1") event_block("Join", method)
    if (name == "Control" && action == "3") event_block("LiveEnded", method)
}

function response(    tag, f, w, len, se, n, i, ack, ext, s2, e2, t, f2, w2, l2) {
    P = 0; n = 0; ack = 0; ext = ""
    while (P < NB) {
        tag = varint() + 0
        f = int(tag / 8)
        w = tag % 8
        if (w == 0) { v = varint(); if (f == 9) ack = (v != "0"); continue }
        if (w == 2) {
            len = varint() + 0
            se = P + len
            if (f == 1) {
                n++
                MT[n] = ""; MS[n] = 0; ME[n] = 0
                while (P < se) {
                    t = varint() + 0
                    f2 = int(t / 8); w2 = t % 8
                    if (w2 == 0) { v = varint(); continue }
                    if (w2 != 2) { P = se; break }
                    l2 = varint() + 0
                    if (f2 == 1) MT[n] = text(P, P + l2)
                    else if (f2 == 2) { MS[n] = P; ME[n] = P + l2 }
                    P += l2
                }
            } else if (f == 5) ext = hexs(P, se)
            P = se
            continue
        }
        if (w == 1) { P += 8; continue }
        if (w == 5) { P += 4; continue }
        break
    }
    printf "A\t%d\t%s\n", ack, ext
    for (i = 1; i <= n; i++) emit_event(MT[i], MS[i], ME[i])
}

function frame(    tag, f, w, len, ptype, logid, payload) {
    P = 0; ptype = ""; logid = "0"; payload = ""
    while (P < NB) {
        tag = varint() + 0
        f = int(tag / 8)
        w = tag % 8
        if (w == 0) { v = varint(); if (f == 2) logid = v; continue }
        if (w == 2) {
            len = varint() + 0
            if (f == 7) ptype = text(P, P + len)
            else if (f == 8) payload = hexs(P, P + len)
            P += len
            continue
        }
        if (w == 1) { P += 8; continue }
        if (w == 5) { P += 4; continue }
        break
    }
    printf "%s\t%s\t%s\n", ptype, logid, payload
}

{
    load_bytes($0)
    if (mode == "frame") frame()
    else if (mode == "response") response()
    else if (mode == "msg") { BUF = ""; split("", FIELD); split("", CNT); decode(type, 0, NB, ""); printf "%s", BUF }
}
