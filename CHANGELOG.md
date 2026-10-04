# Changelog

## 0.3.0 — parity rewrite

### Breaking
- The library is now several files (`lib/piratetok.sh` + `pt_*.sh`, `pt_*.awk`, `piratetok.proto`, `pt_events.tsv`); install copies all of `lib/`.
- `pt_check_online` prints `LIVE:<room>:<anchor>` (was `LIVE:<room>`), plus `APIERROR:<code>` / `BLOCKED` / `ERROR`.
- `on_error` no longer exits; API calls return non-zero with `PT_ERROR`.
- `pt_fetch_ttwid` / `pt_resolve_room` / `pt_wss_open` / `pt_read_loop` keep their names, but `pt_connect` now runs the reconnect loop.

### Added (F1–F19 of the 2026-10 parity spec)
- Schema-driven protobuf decoder in POSIX awk: all 64 Tier A/B events typed, `Unknown` with its raw payload, exact int64 values. Sub-routing (raw + Follow/Share/Join/LiveEnded).
- Reconnect loop: stale watchdog, backoff 2→30 s, `PT_MAX_RETRIES` counting consecutive failures (a 30 s healthy session resets it), ttwid retry 8×750 ms, ttwid+UA reuse, rotation on DEVICE_BLOCKED / early death, `on_reconnecting` / `on_disconnected`, `pt_disconnect`.
- `PT_PROXY` (HTTP CONNECT + Basic auth) for HTTP and WSS; `PT_COOKIES`; `PT_LANGUAGE`/`PT_REGION`; `PT_COMPRESS`; `heartbeat_duration` follows `PT_HEARTBEAT_SEC`.
- Room info (+ FLV URLs, AgeRestricted), audience roster (+ SessionRequired), top viewers, cached profile scrape, gift/like/badge helpers, `ApiError` / `TikTokBlocked` mapping.
- WebSocket: ping/pong, close, fragmentation; needs_ack acks.
- 6 examples; offline tests: `check.sh`, `unit.sh` (54), `replay.sh` (36 checks over 6 captures), `wire.sh` (30 against local TLS fakes).

### Fixed
- TLS peers were never verified (`openssl s_client` without `-verify_return_error`). Certificates and hostname/IP are now checked against the system trust store (`PT_CAFILE` to add a CA).
- `pt_wss_close` no longer runs a bare `wait` that blocked on the caller's own background jobs.
- Homepage: https://piratetok.rosint.org

### Limits
- No SOCKS proxies (openssl s_client only does HTTP CONNECT); rejected with an explicit error.
