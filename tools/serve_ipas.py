#!/usr/bin/env python3
"""Serve queued IPAs over plain HTTP so the phone can just open a link.

LocalSend needs mutual discovery, and this LAN is not delivering discovery in either
direction, so this is the path that cannot fail: the phone opens a URL on the same
Wi-Fi and taps the file. No app, no pairing, no multicast.

usage:
    serve_ipas.py --dir C:/Users/Aiden/Desktop/Wandering/outbox --port 8080
"""
from __future__ import annotations

import argparse
import html
import os
import socket
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlparse


def human(size: int) -> str:
    if size >= 1 << 20:
        return f"{size / (1 << 20):.1f} MB"
    return f"{size / 1024:.0f} KB"


def make_handler(root: str, port: int):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass

        def _index(self) -> bytes:
            files = sorted(
                (name for name in os.listdir(root)
                 if os.path.isfile(os.path.join(root, name)) and not name.startswith(".")),
                key=lambda n: os.path.getmtime(os.path.join(root, n)),
                reverse=True,
            )
            rows = []
            for name in files:
                path = os.path.join(root, name)
                stat = os.stat(path)
                stamp = datetime.fromtimestamp(stat.st_mtime).strftime("%b %d %H:%M")
                rows.append(
                    f"<li><a href=\"/f/{quote(name)}\"><b>{html.escape(name)}</b></a>"
                    f"<span>{human(stat.st_size)} · {stamp}</span></li>"
                )
            body = "\n".join(rows) or "<li><span>empty</span></li>"
            return f"""<!doctype html><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Wandering — builds</title>
<style>
 :root {{ color-scheme: dark; }}
 body {{ margin:0; padding:28px 20px 48px; background:#141210; color:#f3ece4;
        font:16px/1.45 -apple-system,system-ui,sans-serif; }}
 h1 {{ font-size:20px; margin:0 0 4px; letter-spacing:-.01em; }}
 p  {{ color:#9d948b; margin:0 0 22px; font-size:14px; }}
 ul {{ list-style:none; margin:0; padding:0; }}
 li {{ border-top:1px solid #2b2620; padding:14px 0; display:flex;
       justify-content:space-between; align-items:baseline; gap:12px; }}
 a  {{ color:#e0783f; text-decoration:none; font-weight:600; }}
 span {{ color:#9d948b; font-size:12px; white-space:nowrap; }}
 code {{ background:#221d19; padding:2px 6px; border-radius:5px; font-size:12px; }}
</style>
<h1>Wandering — builds</h1>
<p>Tap a file to download. Side-load with your installer of choice.</p>
<ul>{body}</ul>""".encode()

        def do_GET(self):
            path = urlparse(self.path).path
            if path in ("/", "/index.html"):
                payload = self._index()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return

            if path.startswith("/f/"):
                name = os.path.basename(unquote(path[3:]))
                target = os.path.join(root, name)
                if not os.path.isfile(target):
                    self.send_error(404)
                    return
                size = os.path.getsize(target)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition",
                                 f"attachment; filename=\"{name}\"")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                sent = 0
                with open(target, "rb") as handle:
                    while chunk := handle.read(1 << 16):
                        self.wfile.write(chunk)
                        sent += len(chunk)
                print(f"[serve] {self.client_address[0]} fetched {name} "
                      f"({sent / 1048576:.1f} MB)", flush=True)
                return

            self.send_error(404)

    return Handler


def lan_ip() -> str:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("192.168.1.254", 80))
        return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        sock.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                      "..", "outbox"))
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    root = os.path.abspath(args.dir)
    os.makedirs(root, exist_ok=True)
    ip = lan_ip()
    server = ThreadingHTTPServer(("0.0.0.0", args.port), make_handler(root, args.port))
    server.daemon_threads = True
    print(f"[serve] http://{ip}:{args.port}/  ->  {root}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
