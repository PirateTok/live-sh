<p align="center">
  <img src="https://raw.githubusercontent.com/PirateTok/.github/main/profile/assets/og-banner-v2.png" alt="PirateTok" width="640" />
</p>

# piratetok-live-sh

TikTok Live client in POSIX sh. The whole stack is plain shell tools: hand-rolled WebSocket framing, a schema-driven protobuf decoder in awk (all 64 typed events, Unknown passthrough), auto-reconnect, proxy support and the shared PirateTok helpers. Nothing but `sh`, `openssl`, `awk`, `gzip` and coreutils.

```
$ tiktok-live zooich
[*] connected to zooich (room 7352941680123)
[chat] Maria (@maria_xyz): hello from Romania!
[gift] Alex (@alex99) sent Rose x5 (5 diamonds)
[like] João (@jp_live) (4821 total)
[join] Sofia (@sofia_abc)
```

## Install

```bash
bpkg install PirateTok/live-sh
```

Or manually: copy `lib/*` to `/usr/local/lib/piratetok/` and `tiktok-live.sh` to `/usr/local/bin/tiktok-live`. Set `PT_LIB_DIR` if the library lives elsewhere.

## Library usage

```sh
. /usr/local/lib/piratetok/piratetok.sh

on_chat()         { echo "CHAT $1: $2"; }               # USER CONTENT
on_gift()         { pt_gift_streak; echo "GIFT $1 $2 +$PT_STREAK_EVENT_COUNT"; }
on_like()         { echo "LIKE $1 ($2 total)"; }
on_top_viewer()   { echo "TOP #$1 $3 score=$2"; }       # RANK SCORE NICK UNIQUE_ID USER_ID
on_event()        { :; }                                # every event: $1 = name, fields via pt_field / pt_get
on_reconnecting() { echo "retry $1/$2 in ${3}s"; }
on_disconnected() { echo "bye"; }

trap 'pt_disconnect' INT
pt_connect "username_here"      # blocks; reconnects until pt_disconnect or max retries
```

### Events

`on_event NAME METHOD` fires for every decoded event, with the fields in `PT_EV_FIELDS` (`path<TAB>value` lines, e.g. `user.nickname`, `ranks_list.0.score`, `gift_details.diamond_count`). Read them with `pt_field PATH` or `pt_get PATH...` (→ `$_g1..$_g9`). Names match live-rs: `Chat`, `Gift`, `Like`, `Member`, `Social`, `RoomUserSeq`, `Control`, the sub-routed `Follow` / `Share` / `Join` / `LiveEnded` (both the raw and the convenience event fire), all Tier A/B types (`Envelope`, `LinkMicBattle`, `SubNotify`, …), and `Unknown` (method + raw payload hex). Typed fields come from `lib/piratetok.proto` (generated from live-lua by `tools/gen_schema.sh`; same tags as live-rs). int64 IDs stay exact.

Convenience handlers: `on_chat USER CONTENT`, `on_gift USER NAME REPEAT DIAMONDS`, `on_like USER TOTAL`, `on_join USER`, `on_follow USER`, `on_share USER`, `on_viewers COUNT`, `on_top_viewer RANK SCORE NICK UNIQUE_ID USER_ID` (the top-viewers box, sorted by rank), `on_ended`, `on_unknown METHOD HEX`, `on_connected ROOM`, `on_reconnecting ATTEMPT MAX DELAY`, `on_disconnected`, `on_status MSG`, `on_error MSG`.

### API calls (no WebSocket)

| Call | Result |
|---|---|
| `pt_check_online USER` | prints `LIVE:<room_id>:<anchor_id>`, `OFF`, `404`, `APIERROR:<code>`, `BLOCKED` or `ERROR`. `pt_resolve_room USER` sets `PT_ONLINE`, `PT_ROOM_ID`, `PT_ANCHOR_ID`, `PT_ERROR` |
| `pt_fetch_room_info ROOM [COOKIES]` | `PT_INFO_TITLE/VIEWERS/LIKES/TOTAL/OWNER_ID`, `PT_INFO_FLV_ORIGIN/HD/SD/LD/AO`; 18+ rooms without cookies → `AGE_RESTRICTED` |
| `pt_fetch_room_audience ROOM ANCHOR\|"" COOKIES` | `on_audience_viewer RANK SCORE USER_ID USERNAME NICK FOLLOWERS VERIFIED IS_FOLLOWER IS_FOLLOWING IS_SUB SEC_UID AVATAR` per named viewer; `PT_AUD_TOTAL`, `PT_AUD_ANON`. Login-gated: without session cookies → `SESSION_REQUIRED` |
| `pt_fetch_profile USER` | `PT_PROFILE_*` (HD avatars, counts, bio link…). Cached in `PT_CACHE_DIR` for `PT_PROFILE_TTL` s, private/not-found negatively cached |

Errors are `PT_ERROR="KIND: detail"`: `USER_NOT_FOUND`, `HOST_NOT_ONLINE`, `API_ERROR`, `TIKTOK_BLOCKED` (HTTP 403/429, empty or non-JSON body), `AGE_RESTRICTED`, `SESSION_REQUIRED`, `INVALID_RESPONSE`, `HTTP`, `PROFILE_*`.

### Helpers

`pt_gift_is_combo`, `pt_gift_is_streak_over`, `pt_gift_diamond_total`, `pt_gift_streak` (GiftStreakTracker → `PT_STREAK_*`), `pt_like_accumulate` (LikeAccumulator → `PT_LIKE_TOTAL` monotonic, `PT_LIKE_ACCUMULATED`, `PT_LIKE_BACKWARDS`), `pt_gifter_level`, `pt_member_level`, `pt_is_moderator`, `pt_is_top_gifter`.

### Configuration (env or variables, before calling `pt_*`)

| Variable | Default | |
|---|---|---|
| `PT_CDN` / `PT_WS_PORT` | `webcast-ws.tiktok.com` / 443 | EU `webcast-ws.eu.tiktok.com`, US `webcast-ws.us.tiktok.com` |
| `PT_HEARTBEAT_SEC` | 10 | also sent as `heartbeat_duration` |
| `PT_STALE_SEC` | 60 | no data for this long → reconnect |
| `PT_MAX_RETRIES` | 5 | consecutive failures; a 30 s healthy session resets it; 0 = no reconnect |
| `PT_UA` | random pool | fixed User-Agent |
| `PT_COOKIES` | | session cookies appended after ttwid on the WebSocket |
| `PT_PROXY` | | `http://[user:pass@]host:port` (HTTP CONNECT) for every HTTP call and the WebSocket |
| `PT_LANGUAGE` / `PT_REGION` | from `LANG` / en, US | |
| `PT_COMPRESS` | 1 | gzip WebSocket payloads |
| `PT_CAFILE` | system trust store | extra CA bundle; TLS peers are always verified (hostname / IP checked) |
| `PT_WEB_HOST`, `PT_WEBCAST_HOST` (+ `_PORT`) | TikTok | override endpoints (local fakes, mirrors) |

Reconnects: a cookie-less ttwid response is retried 8× (750 ms apart) before it counts as a failed attempt. The ttwid + UA pair is reused across reconnects and rotated on `DEVICE_BLOCKED` (retry in 2 s) or after a connection that died within 30 s. Backoff is 2 → 4 → 8 → 16 → 30 s.

## Limits

- **No SOCKS proxies.** `openssl s_client` only tunnels through HTTP CONNECT, so `socks5://` is rejected with an explicit error.
- Throughput: every frame goes through `od`/`awk`/`gzip` processes. It's fine for normal rooms, but it's a shell. Use live-rs/live-c for heavy rooms.
- `PT_TTWID_DELAY` uses fractional `sleep` (GNU/busybox). On shells without it, the delay falls back to 1 s.

## Tests (offline)

```bash
sh tests/check.sh     # dash -n on every script incl. examples, awk parses under busybox, 800-LOC limit
sh tests/unit.sh      # policy, parsers, decoder + dispatch, helpers, URL params, proxy parsing, JSON
ln -s ../live-rs/testdata testdata   # or PIRATETOK_TESTDATA=…
sh tests/replay.sh    # all captures vs manifests: event types, sub-routing, likes, gift streaks
sh tests/wire.sh      # needs python3: TLS fakes for ttwid/room/WebSocket/proxy, the full client end-to-end
```

## Examples

`examples/online_check.sh`, `basic_chat.sh`, `stream_info.sh`, `gift_streak.sh`, `profile_lookup.sh`, `audience.sh`.

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
| **Elixir** | `{:piratetok_live, "~> 0.2"}` | [live-ex](https://github.com/PirateTok/live-ex) |
| **Dart** | `dart pub add piratetok_live` | [live-dart](https://github.com/PirateTok/live-dart) |
| **C** | `#include "piratetok.h"` | [live-c](https://github.com/PirateTok/live-c) |
| **PowerShell** | `Install-Module PirateTok.Live` | [live-ps1](https://github.com/PirateTok/live-ps1) |

Website: https://piratetok.rosint.org

## License

0BSD
