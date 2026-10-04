# pt_unhex.awk - write the bytes of a lowercase hex line to stdout (run with LC_ALL=C)
BEGIN { for (i = 0; i < 256; i++) V[sprintf("%02x", i)] = i }
{ n = int(length($0) / 2); for (i = 0; i < n; i++) printf "%c", V[substr($0, 2 * i + 1, 2)] }
