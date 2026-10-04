# pt_mask.awk - prepend header hex + mask key and XOR-mask a hex payload (RFC 6455 client frame)
BEGIN { for (i = 0; i < 256; i++) { h = sprintf("%02x", i); V[h] = i; S[i] = h } }
function bxor(a, b,    r, bit) { r = 0; for (bit = 1; bit < 256; bit *= 2) { if ((int(a / bit) % 2) != (int(b / bit) % 2)) r += bit } return r }
{
    for (i = 0; i < 4; i++) M[i] = V[substr(mask, 2 * i + 1, 2)]
    out = hdr mask
    n = int(length($0) / 2)
    for (i = 0; i < n; i++) out = out S[bxor(V[substr($0, 2 * i + 1, 2)], M[i % 4])]
    print out
}
