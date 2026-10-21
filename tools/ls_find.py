#!/usr/bin/env python3
"""Find LocalSend receivers on the LAN by asking port 53317 who they are.

Why not mDNS: this host sees no multicast traffic at all (no _airplay, no _raop,
no _localsend), so Bonjour discovery is blind here even with the phone awake. A
receiver only answers this scan while its Receive screen is open, so a hit *is* the
phone, and the alias in /api/localsend/v2/info confirms which device it is.

usage:
    ls_find.py                        # scan 192.168.1.0/24
    ls_find.py --range 192.168.50     # another subnet
    ls_find.py --only 192.168.1.0/24  # keep to one CIDR
"""
from __future__ import annotations

import argparse
import concurrent.futures as futures
import ipaddress
import json
import socket
import time
import urllib.request


def probe(ip: str, port: int, timeout: float) -> dict | None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        if sock.connect_ex((ip, port)) != 0:
            return None
    finally:
        sock.close()
    try:
        with urllib.request.urlopen(f"http://{ip}:{port}/api/localsend/v2/info",
                                    timeout=3) as response:
            info = json.loads(response.read() or b"{}")
    except Exception:
        info = {}
    return {"ip": ip, "port": port, "info": info}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cidr", default="192.168.1.0/24")
    parser.add_argument("--port", type=int, default=53317)
    parser.add_argument("--timeout", type=float, default=0.45)
    parser.add_argument("--workers", type=int, default=128)
    args = parser.parse_args()

    network = ipaddress.ip_network(args.cidr, strict=False)
    hosts = [str(ip) for ip in network.hosts()]
    started = time.time()
    hits: list[dict] = []
    with futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for result in pool.map(lambda ip: probe(ip, args.port, args.timeout), hosts):
            if result:
                hits.append(result)

    elapsed = time.time() - started
    if not hits:
        print(f"no LocalSend receiver answered on {args.cidr} port {args.port} "
              f"({len(hosts)} addresses in {elapsed:.1f}s)")
        return 1

    for hit in hits:
        info = hit["info"]
        print(f"{hit['ip']}:{hit['port']}  alias={info.get('alias')!r} "
              f"type={info.get('deviceType')} model={info.get('deviceModel')} "
              f"protocol={info.get('protocol')}")
    print(f"({len(hosts)} addresses in {elapsed:.1f}s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
