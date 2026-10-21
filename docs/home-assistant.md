# Controlling Plezy from Home Assistant

Plezy can act as a **Plex Companion** player. Home Assistant's built-in Plex
integration then discovers it as a `media_player` and can play, pause, seek,
change volume, skip, stop, and start media on it.

Tested design target: Plezy on Windows 11, Home Assistant OS on another machine
on the same LAN.

## 1. Enable it in Plezy

Settings → Controls → **Plex Companion (Home Assistant)**. It is off by default
because Plex Companion has no authentication: while it is on, any device on
your network can control Plezy.

## 2. Allow it through Windows Firewall

Home Assistant needs two inbound ports: **UDP 32412** (to find Plezy) and
**TCP 32500** (to control it). Windows only honours firewall rules for the
network type your connection uses, and many home networks are labelled
**Public** by default, which silently blocks both. The easiest fix is the
included script. Open PowerShell **as administrator** in the Plezy folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\allow_plex_companion_firewall.ps1 -MakeNetworkPrivate
```

It shows your connections, switches Public ones to Private (only do this on a
network you trust), and creates both rules for your local subnet. Without
`-MakeNetworkPrivate` it only warns about Public connections.

Doing it by hand instead:

```powershell
New-NetFirewallRule -DisplayName "Plezy Plex Companion TCP" -Direction Inbound -Protocol TCP -LocalPort 32500 -Action Allow -Profile Private
New-NetFirewallRule -DisplayName "Plezy Plex Companion UDP" -Direction Inbound -Protocol UDP -LocalPort 32412 -Action Allow -Profile Private
```

## 3. Home Assistant

Add the **Plex** integration (Settings → Devices & services) pointing at the
same Plex server Plezy is signed in to. With Plezy running and the setting on,
a `media_player` named after your PC appears within about a minute.
HA must be able to reach the PC by UDP broadcast, so HAOS and the PC must be on
the same subnet/VLAN.

Play something (use the entity id you see in HA, under Settings > Devices &
services > Entities, search "plex"). In Developer tools > Actions:

```yaml
action: media_player.play_media
target:
  entity_id: media_player.YOUR_PLEZY_ENTITY
data:
  media_content_type: movie
  media_content_id: 'plex://{"library_name": "Movies", "title": "Big Buck Bunny"}'
```

An episode:

```yaml
action: media_player.play_media
target:
  entity_id: media_player.YOUR_PLEZY_ENTITY
data:
  media_content_type: episode
  media_content_id: 'plex://{"library_name": "TV Shows", "show_name": "Some Show", "season_number": 1, "episode_number": 2}'
```

A playlist, shuffled:

```yaml
action: media_player.play_media
target:
  entity_id: media_player.YOUR_PLEZY_ENTITY
data:
  media_content_type: playlist
  media_content_id: 'plex://{"playlist_name": "My Playlist", "shuffle": 1}'
```

Home Assistant turns a playlist, a shuffle (`"shuffle": 1`) or a "continuous"
request (`"continuous": 1`) into a Plex play queue and sends Plezy the queue's
id. Plezy follows that queue, so next/previous use the queue's order (random
for a shuffle). If Plezy cannot read the queue, for example because it is signed
in as a different Plex user than the one Home Assistant uses, it plays the
first item and then continues with the next episodes of that show, and its log
says `could not read play queue`.

Starting media while something is already playing replaces it. Inside the JSON,
`"offset": 90` starts 90 **seconds** in, and `"resume": true` continues where
you left off. With neither, playback starts at the beginning.

## 4. Troubleshooting

### Home Assistant only shows the player while something is playing

Home Assistant lists a player from any of three routes:

1. **UDP discovery.** It broadcasts a search to port 32412 and Plezy answers.
2. **The Plex server's player list.** Plezy registers itself with the server.
3. **An active playback session.** This route only exists while media plays.

If you only ever see the player during playback, routes 1 and 2 are not
working. Find out which one with the checker, run from a **different**
computer on your network (ideally one near Home Assistant):

```
pip install plexapi
python scripts/plex_companion_check.py --server http://YOUR_PLEX_SERVER:32400 --token YOUR_PLEX_TOKEN
```

(`--server` and `--token` are optional; they add the check of route 2. Your
Plex token is in the XML of any item: Plex Web > a title > `...` > Get Info >
View XML, and the address ends with `X-Plex-Token=`.)

Its verdict tells you what to fix:

| Verdict | What it means and what to do |
|---|---|
| PASS | Plezy is discoverable. If Home Assistant still does not list it, use the Home Assistant log check below. |
| PARTIAL: control works but no UDP answer | Windows is not letting the search reach Plezy. Run the firewall script above (with `-MakeNetworkPrivate` if your network is Public). Also check Plezy's log (Settings > View Logs) for `GDM: CANNOT listen on UDP 32412`, which means another Plex app on the same PC owns the port. |
| PARTIAL: found but TCP unreachable | Allow TCP 32500 through the firewall (script above). |
| FAIL: not found | Plezy is not running past sign-in, or the Plex Companion switch is off. |
| "server does NOT list Plezy" | Plezy's announcement did not reach your Plex server. The server needs *Enable local network discovery (GDM)* on (Plex > Settings > Network), and it must be on the same network. A Docker server using bridge networking, or one on another subnet, never receives it. Route 1 alone is enough, so fix that first. |

**Home Assistant log check.** In Home Assistant: Settings > Devices & services >
Plex > the `...` menu > *Enable debug logging*. Wait a minute, then open
Settings > System > Logs > *Show raw logs* and look for these lines:

- `Scanning for GDM clients`: Home Assistant is searching. Normal.
- `Direct client connection failed, will try again: ... (http://IP:PORT)`: Plezy
  answered the search but Home Assistant could not reach that address. Allow
  TCP 32500, and check that the IP shown is the PC's real LAN address (not a
  virtual adapter).
- Neither of the above after a scan with Plezy running: the search never got an
  answer, which is route 1 failing (firewall/profile/subnet).

**What Plezy logs.** In Plezy's log (Settings > View Logs):

- `GDM: listening for player searches on UDP 32412`: ready for searches.
- `GDM: answered a player search from <ip>`: Home Assistant's search arrived.
  If you see this but Home Assistant still shows nothing, the problem is on
  Home Assistant's side of the connection (see above).
- `Companion: control request from <ip>`: Home Assistant reached the control port.
- `PlexCompanion: this computer's IPv4 addresses`: lists every network adapter.
  Virtual adapters (WSL, Hyper-V, VPN) can make a PC advertise an address the
  rest of the network cannot reach.

### Other symptoms

| Symptom | Likely cause |
|---|---|
| "no Plezy found" | setting off, Plezy not on a signed-in profile yet, firewall, or different subnet |
| Found, but `/resources` fails | TCP 32500 blocked (or Plezy chose another port: log says "using a free port") |
| Entity appears but `play_media` errors 404 | Plezy is not signed in to the server HA is using |
| Plex Media Server runs on the *same* PC | both want UDP 32412. Plezy keeps retrying to bind it every minute; the log says so |

## Limits

Video only (no music/photos), no iOS, no plex.tv-relayed control (LAN only),
no audio/subtitle track selection from HA, `skipTo` is accepted but ignored.
