#!/usr/bin/env python3
"""LocalSend receiver + mDNS announcer for the desktop.

Why this exists: the phone could not be reached at its old address, so instead of
guessing addresses, this makes the desktop *visible* — it advertises itself as a
LocalSend device so the phone lists it under Nearby devices, and it accepts what
the phone sends. Every request is logged with the sender's address, which also
tells us the phone's current IP so the outbox can be re-pointed at it.

Implements the parts of LocalSend v2 that matter for receiving:
    GET  /api/localsend/v2/info
    POST /api/localsend/v2/register
    POST /api/localsend/v2/prepare-upload
    POST /api/localsend/v2/upload?sessionId=&fileId=&token=
    POST /api/localsend/v2/cancel

usage:
    ls_receiver.py                       # announce + receive into ./received
    ls_receiver.py --dir C:/some/dir --alias "DESKTOP-IGL86NN" --no-mdns
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import threading
import time
import uuid
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DEFAULT_PORT = 53317
FINGERPRINT = uuid.uuid5(uuid.NAMESPACE_DNS, socket.gethostname()).hex[:32]
VERSION = "2.1"


def log(message: str) -> None:
    stamp = datetime.now().strftime("%H:%M:%S")
    print(f"[{stamp}] {message}", flush=True)


class State:
    def __init__(self, alias: str, port: int, outbox: str) -> None:
        self.alias = alias
        self.port = port
        self.outbox = outbox
        self.sessions: dict[str, dict] = {}
        self.sender_ips: set[str] = set()

    def info(self, protocol: str = "http") -> dict:
        return {
            "alias": self.alias,
            "version": VERSION,
            "deviceModel": "Windows",
            "deviceType": "desktop",
            "fingerprint": FINGERPRINT,
            "port": self.port,
            "protocol": protocol,
            "download": False,
        }


def make_handler(state: State):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # keep stdout for our own log
            pass

        # -- helpers ---------------------------------------------------
        def _json(self, code: int, payload: dict) -> None:
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self) -> bytes:
            length = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(length) if length else b""

        def _peer(self) -> str:
            return self.client_address[0]

        # -- routes ----------------------------------------------------
        def do_GET(self):
            path = urlparse(self.path).path
            if path in ("/api/localsend/v2/info", "/api/localsend/v1/info"):
                state.sender_ips.add(self._peer())
                self._json(200, state.info())
            else:
                self._json(404, {"message": "not found"})

        def do_POST(self):
            parsed = urlparse(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            peer = self._peer()

            if path == "/api/localsend/v2/register":
                payload = json.loads(self._body() or b"{}")
                info = payload.get("info") or payload
                state.sender_ips.add(peer)
                log(f"register from {peer} · alias={info.get('alias')!r} "
                    f"type={info.get('deviceType')} model={info.get('deviceModel')}")
                self._json(200, state.info())
                return

            if path == "/api/localsend/v2/prepare-upload":
                payload = json.loads(self._body() or b"{}")
                files = payload.get("files") or {}
                info = payload.get("info") or {}
                session = uuid.uuid4().hex
                tokens = {}
                plan = {}
                for file_id, meta in files.items():
                    name = os.path.basename(meta.get("fileName") or f"{file_id}.bin")
                    plan[file_id] = {"name": name, "size": int(meta.get("size") or 0)}
                    tokens[file_id] = uuid.uuid4().hex
                state.sessions[session] = {"files": plan, "tokens": tokens,
                                           "from": peer, "alias": info.get("alias")}
                state.sender_ips.add(peer)
                total = sum(p["size"] for p in plan.values())
                log(f"prepare-upload from {peer} · {len(plan)} file(s), "
                    f"{total/1048576:.1f} MB · session {session[:8]}")
                self._json(200, {"sessionId": session, "files": tokens})
                return

            if path == "/api/localsend/v2/upload":
                session_id = (query.get("sessionId") or [""])[0]
                file_id = (query.get("fileId") or [""])[0]
                token = (query.get("token") or [""])[0]
                session = state.sessions.get(session_id)
                if not session or session["tokens"].get(file_id) != token:
                    log(f"upload refused: bad session/token from {peer}")
                    self._json(403, {"message": "invalid session or token"})
                    return

                plan = session["files"][file_id]
                os.makedirs(state.outbox, exist_ok=True)
                target = os.path.join(state.outbox, plan["name"])
                base, ext = os.path.splitext(target)
                counter = 1
                while os.path.exists(target):
                    target = f"{base} ({counter}){ext}"
                    counter += 1

                length = int(self.headers.get("Content-Length") or 0)
                remaining = length
                with open(target, "wb") as handle:
                    while remaining > 0:
                        chunk = self.rfile.read(min(remaining, 1 << 20))
                        if not chunk:
                            break
                        handle.write(chunk)
                        remaining -= len(chunk)
                size = os.path.getsize(target)
                log(f"received {plan['name']} ({size/1048576:.1f} MB) from {peer} "
                    f"-> {target}")
                self._json(200, {"message": "ok"})
                return

            if path == "/api/localsend/v2/cancel":
                payload = json.loads(self._body() or b"{}")
                session_id = payload.get("sessionId", "")
                if session_id in state.sessions:
                    del state.sessions[session_id]
                    log(f"cancel {session_id[:8]} from {peer}")
                self._json(200, {"message": "ok"})
                return

            self._json(404, {"message": "not found"})

    return Handler


def _lan_addresses() -> list[str]:
    """Real unicast LAN addresses, best first.

    `gethostname()` on this box resolves to the Tailscale link-local address, which
    would advertise an address nothing on the LAN can reach — so ask the routing
    table which address the OS would actually use, and drop 169.254/127.x.
    """
    addresses: list[str] = []
    for probe in ("192.168.1.254", "1.1.1.1"):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.connect((probe, 80))
            addr = sock.getsockname()[0]
            if addr and not addr.startswith(("169.254.", "127.")) and addr not in addresses:
                addresses.append(addr)
        except OSError:
            pass
        finally:
            sock.close()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addr = info[4][0]
            if addr.startswith(("169.254.", "127.")) or addr in addresses:
                continue
            addresses.append(addr)
    except OSError:
        pass
    return addresses


def announce(state: State, service_name: str):
    """Advertise ourselves so the phone lists the desktop under Nearby devices."""
    try:
        from zeroconf import IPVersion, ServiceInfo, Zeroconf
    except ImportError:
        log("zeroconf missing — run: python -m pip install zeroconf")
        return None

    raw = _lan_addresses()
    if not raw:
        log("no usable IPv4 address — advertising without an A record")
        return None
    addresses = [socket.inet_aton(addr) for addr in raw]

    service = ServiceInfo(
        "_localsend._tcp.local.",
        f"{service_name}._localsend._tcp.local.",
        addresses=addresses,
        port=state.port,
        properties={
            "alias": state.alias,
            "version": VERSION,
            "deviceModel": "Windows",
            "deviceType": "desktop",
            "fingerprint": FINGERPRINT,
            "port": str(state.port),
            "protocol": "http",
            "download": "false",
        },
        server=f"{socket.gethostname()}.local.",
    )
    zc = Zeroconf(ip_version=IPVersion.V4Only)
    zc.register_service(service)
    log(f"announcing {state.alias} on _localsend._tcp as "
        f"{socket.inet_ntoa(addresses[0])}:{state.port}")
    return zc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--alias", default=socket.gethostname())
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                      "..", "received"))
    parser.add_argument("--no-mdns", action="store_true")
    args = parser.parse_args()

    outbox = os.path.abspath(args.dir)
    os.makedirs(outbox, exist_ok=True)
    state = State(args.alias, args.port, outbox)

    zc = None if args.no_mdns else announce(state, args.alias)

    server = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(state))
    server.daemon_threads = True
    log(f"listening on 0.0.0.0:{args.port} · saving to {outbox}")

    reporter = threading.Thread(target=_report_senders, args=(state,), daemon=True)
    reporter.start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("stopping")
    finally:
        if zc is not None:
            zc.close()
        server.server_close()
    return 0


def _report_senders(state: State) -> None:
    """Keep a small file with the addresses that talked to us.

    The phone's IP changes, so this is the authoritative answer for where to point
    the outbox — written from real traffic instead of a guess.
    """
    path = os.path.join(state.outbox, "seen-senders.txt")
    while True:
        time.sleep(5)
        if not state.sender_ips:
            continue
        try:
            with open(path, "w", encoding="utf-8") as handle:
                for ip in sorted(state.sender_ips):
                    handle.write(ip + "\n")
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
