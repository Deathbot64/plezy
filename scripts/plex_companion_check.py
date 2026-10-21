#!/usr/bin/env python3
"""Find out why Home Assistant can or cannot see Plezy.

Home Assistant's Plex integration lists a player from any of three routes:
  1. UDP discovery: it broadcasts a search to port 32412 and Plezy answers.
  2. The Plex server's own /clients list (Plezy registers itself with the server).
  3. An active playback session (this is why a player can appear only while
     something is playing).
This script checks routes 1 and 2, plus the TCP control port, using python-plexapi
(the library Home Assistant uses), and tells you which one is broken.

    pip install plexapi
    python scripts/plex_companion_check.py
    python scripts/plex_companion_check.py --host 192.168.1.50
    python scripts/plex_companion_check.py --server http://192.168.1.10:32400 --token YOUR_PLEX_TOKEN
    python scripts/plex_companion_check.py --host 192.168.1.50 --pause   # also pause/play a running video

Run it from a DIFFERENT computer on your network than the one running Plezy
(ideally one on the same network as Home Assistant), because broadcasts a
computer sends to itself prove very little.
"""
import argparse
import sys
import xml.etree.ElementTree as ET

import requests
from plexapi.client import PlexClient
from plexapi.gdm import GDM


def scan_for_plezy():
    """UDP discovery exactly as Home Assistant does it. Returns (entries, error)."""
    gdm = GDM()
    try:
        gdm.scan(scan_for_clients=True)
    except Exception as e:  # a malformed reply from some player breaks plexapi's scan
        return [], e
    return gdm.entries, None


def pms_clients(server, token):
    """The Plex server's own list of registered players (route 2)."""
    r = requests.get(server.rstrip("/") + "/clients",
                     headers={"X-Plex-Token": token, "Accept": "application/xml"}, timeout=8)
    r.raise_for_status()
    return [dict(e.attrib) for e in ET.fromstring(r.text).findall("Server")]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", help="Plezy's IP address (also tests the TCP port directly)")
    ap.add_argument("--port", type=int, default=32500, help="Companion HTTP port (default 32500)")
    ap.add_argument("--server", help="Plex server URL, e.g. http://192.168.1.10:32400 (checks route 2)")
    ap.add_argument("--token", help="a Plex token (needed with --server)")
    ap.add_argument("--pause", action="store_true", help="send pause, then play, to a running video")
    args = ap.parse_args()

    gdm_hit = None       # (ip, port, identifier) if UDP discovery found Plezy
    tcp_ok = False
    identifier = None

    print("[1] UDP discovery (Home Assistant's first route)")
    print("    Broadcasting a search to port 32412 ...")
    entries, err = scan_for_plezy()
    if err:
        print(f"    FAIL: the scan raised {err!r}. Some player on your network sent a reply plexapi cannot parse.")
    for e in entries:
        d = e["data"]
        mark = "  <-- Plezy" if d.get("Product") == "Plezy" else ""
        print(f"    found: {d.get('Name')!r} product={d.get('Product')} at {e['from'][0]}:{d.get('Port')}{mark}")
        if d.get("Product") == "Plezy":
            gdm_hit = (e["from"][0], int(d["Port"]), d.get("Resource-Identifier"))
    print("    RESULT:", "Plezy answered the search" if gdm_hit else "no answer from Plezy")

    target = gdm_hit or ((args.host, args.port, None) if args.host else None)
    print("\n[2] Control connection (TCP)")
    if target:
        host, port, ident = target
        print(f"    Connecting to http://{host}:{port}/resources ...")
        try:
            c = PlexClient(baseurl=f"http://{host}:{port}", identifier=ident, token="check")
            tcp_ok = "playback" in c.protocolCapabilities
            identifier = c.machineIdentifier
            print(f"    OK: {c.product} {c.version} '{c.title}' id={identifier}")
            print(f"    capabilities: {c.protocolCapabilities}")
            for t in c.timelines():
                extra = f" time={t.time}/{t.duration} volume={t.volume}" if t.state != "stopped" else ""
                print(f"    timeline {t.type}: {t.state}{extra}")
            if args.pause:
                c.pause("video"); c.play("video")
                print("    sent pause, then play")
        except Exception as e:
            print(f"    FAIL: {e!r}")
    else:
        print("    skipped (no address known: discovery found nothing and --host was not given)")

    pms_listed = None
    if args.server:
        print("\n[3] Plex server's own player list (Home Assistant's second route)")
        if not args.token:
            print("    skipped: --token is required with --server")
        else:
            try:
                clients = pms_clients(args.server, args.token)
                print(f"    {len(clients)} player(s) registered with the server")
                pms_listed = False
                for c in clients:
                    hit = (identifier and c.get("machineIdentifier") == identifier) or c.get("product") == "Plezy"
                    pms_listed = pms_listed or bool(hit)
                    print(f"    - {c.get('name')!r} product={c.get('product')} host={c.get('host')} "
                          f"port={c.get('port')}{'  <-- Plezy' if hit else ''}")
                print("    RESULT:", "the server lists Plezy" if pms_listed else "the server does NOT list Plezy")
            except Exception as e:
                print(f"    FAIL: could not read {args.server}/clients: {e!r}")

    print("\n=== Verdict ===")
    if gdm_hit and tcp_ok:
        print("PASS: Plezy is discoverable and controllable, so Home Assistant should list it while idle.")
        print("If it still does not, enable debug logging for the Plex integration in Home Assistant and look for")
        print("'Direct client connection failed' (see docs/home-assistant.md).")
        code = 0
    elif tcp_ok:
        print("PARTIAL: control works, but Plezy did not answer the UDP search. Home Assistant relies on that")
        print("answer to list a player that is idle. Likely causes, most common first:")
        print("  - Windows Firewall blocks UDP 32412 (or the network is set to Public). Run")
        print("    scripts\\allow_plex_companion_firewall.ps1 as administrator on the Plezy PC.")
        print("  - Another Plex app on the Plezy PC (Plex Media Server, Plex HTPC) owns UDP 32412.")
        print("    Plezy's log says 'GDM: CANNOT listen on UDP 32412'.")
        print("  - This computer is on a different subnet/VLAN than the Plezy PC.")
        code = 2
    elif gdm_hit:
        print("PARTIAL: Plezy answered the search, but its control port is unreachable (TCP "
              f"{gdm_hit[1]}). Allow it through Windows Firewall.")
        code = 2
    else:
        print("FAIL: Plezy was not found. Is Plezy running past the sign-in screen with 'Plex Companion' switched on?")
        code = 1
    if pms_listed is False:
        print("Note: the Plex server does not list Plezy either. Plezy tells the server about itself with a UDP")
        print("announcement; that does not reach servers inside a Docker bridge network or on another subnet,")
        print("and the server needs 'Enable local network discovery (GDM)' on (Settings > Network).")
    return code


if __name__ == "__main__":
    sys.exit(main())
