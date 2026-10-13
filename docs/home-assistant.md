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

Your Wi-Fi/Ethernet must be set to a **Private** network. In an *administrator*
PowerShell:

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

Starting media while something is already playing replaces it. Inside the JSON,
`"offset": 90` starts 90 **seconds** in, and `"resume": true` continues where
you left off. With neither, playback starts at the beginning.

## 4. Troubleshooting

Run the checker from any computer on the LAN (ideally one on HA's network):

```
pip install plexapi
python scripts/plex_companion_check.py
```

| Symptom | Likely cause |
|---|---|
| "no Plezy found" | setting off, Plezy not on a signed-in profile yet, firewall, or different subnet |
| Found, but `/resources` fails | TCP 32500 blocked (or Plezy chose another port: log says "using a free port") |
| Entity appears but `play_media` errors 404 | Plezy is not signed in to the server HA is using |
| Plex Media Server runs on the *same* PC | both want UDP 32412. Plezy still registers with the server (HELLO), which HA also reads, but if it is flaky stop one of them |

Log lines start with `PlexCompanion:` / `Companion:` / `GDM:` in Plezy's logs.

## Limits

Video only (no music/photos), no iOS, no plex.tv-relayed control (LAN only),
no audio/subtitle track selection from HA, `skipTo` is accepted but ignored.
