#!/usr/bin/env python3
"""Check that Plezy is discoverable and controllable the way Home Assistant does it.

Uses python-plexapi, the same library Home Assistant's Plex integration uses.
Run it from any machine on the same LAN as the Plezy PC (ideally the HA host):

    pip install plexapi
    python scripts/plex_companion_check.py                 # discover by GDM scan
    python scripts/plex_companion_check.py --host 192.168.1.50   # skip discovery
    python scripts/plex_companion_check.py --host 192.168.1.50 --pause   # also send a command
"""
import argparse
import sys

from plexapi.client import PlexClient
from plexapi.gdm import GDM


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", help="Plezy IP; skips the UDP discovery step")
    ap.add_argument("--port", type=int, default=32500, help="Companion HTTP port (default 32500)")
    ap.add_argument("--pause", action="store_true", help="send pause, then play, to a running video")
    args = ap.parse_args()

    target = None
    if args.host:
        target = (args.host, args.port, None)
    else:
        print("Scanning for Plex players (UDP broadcast to port 32412)...")
        gdm = GDM()
        try:
            gdm.scan(scan_for_clients=True)
        except Exception as e:  # e.g. a malformed reply from some other player
            print(f"FAIL: scan raised {e!r} - a player on your network sent a reply plexapi cannot parse")
            return 1
        for e in gdm.entries:
            d = e["data"]
            print(f"  found: {d.get('Name')!r} product={d.get('Product')} at {e['from'][0]}:{d.get('Port')}")
            if d.get("Product") == "Plezy":
                target = (e["from"][0], int(d["Port"]), d.get("Resource-Identifier"))
        if not target:
            print("FAIL: no Plezy found. Is 'Plex Companion' enabled in Plezy settings, and are Windows "
                  "Firewall rules for UDP 32412 / TCP 32500 allowed on your Private network?")
            return 1

    host, port, ident = target
    print(f"Connecting to http://{host}:{port} ...")
    try:
        c = PlexClient(baseurl=f"http://{host}:{port}", identifier=ident, token="check")
    except Exception as e:
        print(f"FAIL: /resources failed: {e!r}")
        return 1
    print(f"OK: {c.product} {c.version} '{c.title}' id={c.machineIdentifier}")
    print(f"    capabilities: {c.protocolCapabilities}")
    if "playback" not in c.protocolCapabilities:
        print("FAIL: 'playback' capability missing - Home Assistant will not offer controls")
        return 1

    for t in c.timelines():
        extra = f" time={t.time}/{t.duration} ratingKey={t.ratingKey} volume={t.volume}" if t.state != "stopped" else ""
        print(f"    timeline {t.type}: {t.state}{extra}")

    if args.pause:
        c.pause("video"); print("sent pause")
        c.play("video"); print("sent play")
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
