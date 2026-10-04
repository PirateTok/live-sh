#!/usr/bin/env python3
"""Offline fixtures for live-sh wire tests (test-only dependency; the library itself is POSIX sh).

  fixtures.py origin CERT KEY PORTFILE LOG [TTWID_MISSES]  TLS HTTP/1.0 origin: / (ttwid), /api-live/user/room
  fixtures.py ws CERT KEY PORTFILE LOG                     TLS WebSocket server, scripted per connection:
        #0 accept, log hb/enter_room, push a gzip'd needs_ack chat frame, log the ack, close
        #1 reject 415 Handshake-Msg: DEVICE_BLOCKED      #2+ accept and close
  fixtures.py proxy PORTFILE LOG USER PASS                 HTTP CONNECT proxy (Basic auth) relaying TCP
Every request/connection appends one line to LOG.
"""
import base64, gzip, hashlib, os, socket, ssl, struct, sys, threading

def log(path, line):
    with open(path, "a") as f:
        f.write(line + "\n")

def listen(portfile, tls=None):
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0)); srv.listen(16)
    with open(portfile + ".tmp", "w") as f:
        f.write(str(srv.getsockname()[1]))
    os.rename(portfile + ".tmp", portfile)
    return srv

def tls_ctx(cert, key):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key)
    return ctx

def read_head(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(1)
        if not chunk:
            break
        data += chunk
    lines = data.decode("latin-1").split("\r\n")
    headers = {}
    for l in lines[1:]:
        if ":" in l:
            k, v = l.split(":", 1); headers[k.strip().lower()] = v.strip()
    return lines[0], headers

def varint(n):
    out = b""
    while n > 127:
        out += bytes([(n & 127) | 128]); n >>= 7
    return out + bytes([n])

def ld(field, data):
    if isinstance(data, str):
        data = data.encode()
    return varint(field * 8 + 2) + varint(len(data)) + data

def vi(field, n):
    return varint(field * 8) + varint(n)

def parse(buf):
    fields, i = {}, 0
    def rv():
        nonlocal i
        v, s = 0, 0
        while True:
            b = buf[i]; i += 1; v |= (b & 127) << s; s += 7
            if b < 128:
                return v
    while i < len(buf):
        tag = rv(); f, w = tag >> 3, tag & 7
        if w == 0:
            fields[f] = rv()
        elif w == 2:
            l = rv(); fields[f] = buf[i:i + l]; i += l
        else:
            break
    return fields

def origin(cert, key, portfile, logf, misses):
    srv = listen(portfile); ctx = tls_ctx(cert, key); ttwid_hits = [0]
    room = b'{"statusCode":0,"data":{"user":{"roomId":"7001","id":"7378524586521674757","status":2},"liveRoom":{"status":2}}}'
    while True:
        raw, _ = srv.accept()
        try:
            conn = ctx.wrap_socket(raw, server_side=True)
            first, h = read_head(conn)
            path = first.split(" ")[1]
            log(logf, "%s\tua=%s\tcookie=%s\tlang=%s" % (path.split("?")[0], h.get("user-agent", ""), h.get("cookie", ""), h.get("accept-language", "")))
            if path == "/":
                n = ttwid_hits[0]; ttwid_hits[0] += 1
                cookie = "" if n < misses else "Set-Cookie: ttwid=tok%d; Path=/; HttpOnly\r\n" % (n - misses)
                conn.sendall(("HTTP/1.0 200 OK\r\nSet-Cookie: tt_csrf=x\r\n%sContent-Length: 0\r\n\r\n" % cookie).encode())
            elif path.startswith("/api-live/user/room"):
                conn.sendall(b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n" + room)
            elif path.startswith("/@"):
                status = {"/@alice": 0, "/@ghost": 10221, "/@priv": 10222}.get(path, 10221)
                blob = ('{"__DEFAULT_SCOPE__":{"webapp.user-detail":{"statusCode":%d,"userInfo":{"user":{"id":"1","uniqueId":"alice",'
                        '"nickname":"Alice","avatarLarger":"l.jpg","verified":true},"stats":{"followerCount":10,"heartCount":3}}}}}' % status)
                html = '<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">%s</script></html>' % blob
                conn.sendall(b"HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n" + html.encode())
            else:
                conn.sendall(b"HTTP/1.0 404 Not Found\r\n\r\n")
            conn.close()
        except (ssl.SSLError, OSError) as e:
            log(logf, "ERR\t%s" % e)

def ws_frame(payload, opcode=2):
    n = len(payload)
    head = bytes([128 | opcode]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack(">H", n) if n < 65536 else bytes([127]) + struct.pack(">Q", n))
    return head + payload

def ws_read(conn):
    h = conn.recv(2)
    if len(h) < 2:
        return None, None
    op, n = h[0] & 15, h[1] & 127
    if n == 126:
        n = struct.unpack(">H", conn.recv(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", conn.recv(8))[0]
    mask = conn.recv(4) if h[1] & 128 else b"\0\0\0\0"
    data = b""
    while len(data) < n:
        data += conn.recv(n - len(data))
    return op, bytes(b ^ mask[i % 4] for i, b in enumerate(data))

def ws(cert, key, portfile, logf):
    srv = listen(portfile); ctx = tls_ctx(cert, key); idx = 0
    ext = b"ext\xff\x00\xc3"
    user = ld(3, "Ana") + ld(38, "ana")
    chat = ld(2, user) + ld(3, "salut")
    resp = ld(1, ld(1, "WebcastChatMessage") + ld(2, chat)) + ld(5, ext) + vi(9, 1)
    push = vi(2, 77) + ld(7, "msg") + ld(8, gzip.compress(resp))
    while True:
        raw, _ = srv.accept()
        n = idx; idx += 1
        try:
            conn = ctx.wrap_socket(raw, server_side=True)
            first, h = read_head(conn)
            log(logf, "conn%d\tcookie=%s\tua=%s\tlang=%s\tpath=%s" % (n, h.get("cookie", ""), h.get("user-agent", ""), h.get("accept-language", ""), first.split(" ")[1]))
            if n == 1:
                conn.sendall(b"HTTP/1.1 415 Unsupported\r\nHandshake-Msg: DEVICE_BLOCKED\r\nHandshake-Status: 415\r\n\r\n"); conn.close(); continue
            accept = base64.b64encode(hashlib.sha1((h.get("sec-websocket-key", "") + "258EAFA5-E914-47DA-95CA-C5AB0DC11B85").encode()).digest()).decode()
            conn.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
            if n == 0:
                for _ in range(2):
                    op, data = ws_read(conn)
                    f = parse(data); inner = parse(f.get(8, b""))
                    log(logf, "frame\t%s\troom_id=%s" % (f.get(7, b"").decode(), inner.get(1)))
                conn.sendall(ws_frame(push))
                while True:
                    op, data = ws_read(conn)
                    if op is None:
                        break
                    f = parse(data)
                    if f.get(7) == b"ack":
                        log(logf, "ack\tlog_id=%s\text_ok=%s" % (f.get(2), f.get(8) == ext)); break
            conn.sendall(ws_frame(b"", 8)); conn.close()
        except (ssl.SSLError, OSError) as e:
            log(logf, "ERR\t%s" % e)

def relay(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d:
                break
            b.sendall(d)
    except OSError:
        pass
    finally:
        try: b.shutdown(socket.SHUT_WR)
        except OSError: pass

def proxy(portfile, logf, user, password):
    srv = listen(portfile)
    want = "Basic " + base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
    while True:
        conn, _ = srv.accept()
        first, h = read_head(conn)
        target = first.split(" ")[1]
        ok = h.get("proxy-authorization") == want
        log(logf, "%s\t%s\tauth=%s" % (first.split(" ")[0], target, "ok" if ok else "bad"))
        if not ok:
            conn.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n"); conn.close(); continue
        host, port = target.rsplit(":", 1)
        up = socket.create_connection((host, int(port)))
        conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        threading.Thread(target=relay, args=(conn, up), daemon=True).start()
        threading.Thread(target=relay, args=(up, conn), daemon=True).start()

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "origin":
        origin(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6]) if len(sys.argv) > 6 else 0)
    elif cmd == "ws":
        ws(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    elif cmd == "proxy":
        proxy(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
