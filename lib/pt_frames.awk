# pt_frames.awk - split a capture ([u32 LE length][frame]...) given as one hex line into one hex line per frame
{
    n = length($0)
    pos = 1
    while (pos + 8 <= n + 1) {
        len = 0
        for (i = 3; i >= 0; i--) len = len * 256 + H[substr($0, pos + 2 * i, 2)]
        pos += 8
        print substr($0, pos, 2 * len)
        pos += 2 * len
    }
}
BEGIN { for (i = 0; i < 256; i++) H[sprintf("%02x", i)] = i }
