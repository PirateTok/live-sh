<p align="center">
  <img src="https://raw.githubusercontent.com/PirateTok/.github/main/profile/assets/og-banner-v2.png" alt="PirateTok" width="640" />
</p>

# piratetok-live-sh

TikTok Live client in POSIX sh. Decodes chat, gifts, likes, joins, follows, shares, and viewer counts in real-time. Hand-rolled WebSocket framing and protobuf decoding with nothing but shell builtins and `openssl`.

```
$ ./tiktok-live.sh zooich
[*] fetching ttwid...
[*] resolving room for zooich...
[*] connected to zooich (room 7352941680123)
[chat] Maria (@maria_xyz): hello from Romania!
[gift] Alex (@alex99) sent Rose x5 (1 diamonds)
[like] João (@jp_live) (4821 total)
[join] Sofia (@sofia_abc)
[follow] Dan (@dan_ro)
```

## Install

```bash
bpkg install PirateTok/live-sh
```

Or manually:

```bash
cp lib/piratetok.sh /usr/local/lib/piratetok/piratetok.sh
cp tiktok-live.sh /usr/local/bin/tiktok-live
chmod +x /usr/local/bin/tiktok-live
```

## Other languages

| Language | Install | Repo |
|:---------|:--------|:-----|
| **Rust** | `cargo add piratetok-live-rs` | [live-rs](https://github.com/PirateTok/live-rs) |
| **Go** | `go get github.com/PirateTok/live-go` | [live-go](https://github.com/PirateTok/live-go) |
| **Python** | `pip install piratetok-live-py` | [live-py](https://github.com/PirateTok/live-py) |
| **JavaScript** | `npm install piratetok-live-js` | [live-js](https://github.com/PirateTok/live-js) |
| **C#** | `dotnet add package PirateTok.Live` | [live-cs](https://github.com/PirateTok/live-cs) |
| **Java** | `com.piratetok:live` | [live-java](https://github.com/PirateTok/live-java) |
| **Lua** | `luarocks install piratetok-live-lua` | [live-lua](https://github.com/PirateTok/live-lua) |
| **Elixir** | `{:piratetok_live, "~> 0.1"}` | [live-ex](https://github.com/PirateTok/live-ex) |
| **Dart** | `dart pub add piratetok_live` | [live-dart](https://github.com/PirateTok/live-dart) |
| **C** | `#include "piratetok.h"` | [live-c](https://github.com/PirateTok/live-c) |
| **PowerShell** | `Install-Module PirateTok.Live` | [live-ps1](https://github.com/PirateTok/live-ps1) |

## Dependencies

`sh` and `openssl`. That's it.

Runs on any Linux install from this century. Alpine, Debian, Arch, Ubuntu, a Raspberry Pi, your router running OpenWrt. If it has a shell and TLS, it can watch TikTok Live.

## Library usage

`lib/piratetok.sh` is a sourceable library. Define event handlers, then call `pt_connect`:

```sh
#!/bin/sh
. /usr/local/lib/piratetok/piratetok.sh

on_chat()   { echo "CHAT: $1 said $2"; }
on_gift()   { echo "GIFT: $1 sent $2 x$3 ($4 diamonds)"; }
on_like()   { echo "LIKE: $1 ($2 total)"; }
on_join()   { echo "JOIN: $1"; }
on_follow() { echo "FOLLOW: $1"; }
on_share()  { echo "SHARE: $1"; }
on_ended()  { echo "STREAM ENDED"; }

pt_connect "someone"
```

### Low-level API

For reconnection loops or custom flows:

```sh
. /path/to/piratetok.sh

PT_UA=$(pt_random_ua)

pt_fetch_ttwid           # sets PT_TTWID
pt_resolve_room "user"   # sets PT_ROOM_ID, PT_ROOM_RESP
pt_wss_open              # opens WSS on fds 3/4, starts heartbeat
pt_read_loop             # blocking — calls event handlers until disconnect
pt_wss_close             # cleanup
```

### Check online status

```sh
result=$(pt_check_online "someone")
case "$result" in
    LIVE:*) echo "live, room ${result#LIVE:}" ;;
    OFF)    echo "offline" ;;
    404)    echo "not found" ;;
esac
```

### Configuration

Override before calling `pt_*`:

```sh
PT_CDN="webcast-ws.eu.tiktok.com"   # EU / US / Global (default)
PT_HEARTBEAT_SEC=10                  # heartbeat interval
PT_UA="custom UA string"             # override random UA pool
```

### Event handlers

| Handler | Arguments | Event |
|---------|-----------|-------|
| `on_chat` | USER CONTENT | Chat message |
| `on_gift` | USER GIFT_NAME REPEAT DIAMONDS | Gift sent |
| `on_like` | USER TOTAL | Likes |
| `on_join` | USER | Room join |
| `on_follow` | USER | Follow |
| `on_share` | USER | Share |
| `on_viewers` | COUNT | Viewer count update |
| `on_ended` | — | Stream ended |
| `on_status` | MESSAGE | Status update |
| `on_error` | MESSAGE | Fatal error |

## How it works

1. Authenticates and opens a direct WSS connection via `openssl s_client`
2. Resolves username to room ID via TikTok JSON API (raw HTTP)
3. Hand-crafts WebSocket upgrade request with `printf`
4. Builds WebSocket frames — masking, length encoding, the whole RFC 6455 spec
5. Decodes protobuf varints and length-delimited fields with shell arithmetic
6. Decompresses gzip payloads with `gzip -dc`
7. Sends protobuf heartbeats every 10 seconds to keep the connection alive
8. Handles `needs_ack` responses so TikTok doesn't drop us

No curl. No wget. No websocat. No Python. No Node. No external binary except `openssl` for TLS.

## POSIX compliance

No bashisms. No `/dev/tcp`. No `[[ ]]`. No arrays. No `local`. Tested with `dash` and `busybox sh`.

The entire WebSocket protocol and protobuf wire format are implemented in:
- `dd` — read exact byte counts
- `od` — binary to hex
- `printf` — hex to binary
- `cut`/`sed`/`tr` — string manipulation
- `$(( ))` — arithmetic (varint decoding)
- `mkfifo` — bidirectional pipe to openssl
- `gzip -dc` — payload decompression

## Features

- **Zero signing dependency** — no API keys, no signing server, no external auth
- **Sourceable library** — `lib/piratetok.sh` for building your own tools
- **UA rotation** — 6 user agents (3 Firefox, 3 Chrome, mixed OS)
- **System timezone** — auto-detected from env/filesystem, falls back to UTC
- **7 event types** — chat, gift, like, join, follow, share, viewer count
- **Sub-routed convenience events** — follow/share from SocialMessage, join from MemberMessage
- **POSIX sh** — runs on dash, busybox sh, any POSIX-compliant shell

## License

0BSD
