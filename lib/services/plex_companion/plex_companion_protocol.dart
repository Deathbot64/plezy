/// Wire-format builders/parsers for Plex Companion and GDM.
///
/// Everything here is a pure function so it is cheap to test. The formats are
/// what python-plexapi (and therefore Home Assistant) parse; see
/// `docs/home-assistant.md` for the compatibility notes behind each choice.
library;

import 'plex_companion_types.dart';

const String _xmlDeclaration = '<?xml version="1.0" encoding="UTF-8"?>\n';

/// Escapes text for use inside a double-quoted XML attribute.
String xmlEscapeAttribute(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// The body Plex clients return for a successfully accepted command.
String buildOkResponseXml() => '$_xmlDeclaration<Response code="200" status="OK" />';

/// The body for a rejected command (sent with a matching HTTP status).
String buildErrorResponseXml(int code, String message) =>
    '$_xmlDeclaration<Response code="$code" status="${xmlEscapeAttribute(message)}" />';

/// `GET /resources`. python-plexapi's `PlexClient.connect()` reads this and
/// insists one `<Player>` carries the `machineIdentifier` it was told about.
String buildResourcesXml(PlexCompanionDeviceInfo info) {
  final attrs = <String, String>{
    'title': info.name,
    'protocol': 'plex',
    'protocolVersion': '1',
    'protocolCapabilities': info.capabilities,
    'machineIdentifier': info.identifier,
    'product': info.product,
    'platform': info.platform,
    'platformVersion': info.platformVersion,
    'version': info.version,
    'deviceClass': info.deviceClass,
  };
  return '$_xmlDeclaration<MediaContainer size="1">'
      '<Player ${_attributes(attrs)} />'
      '</MediaContainer>';
}

const String _controllable = 'playPause,stop,volume,seekTo,skipPrevious,skipNext,stepBack,stepForward';

/// `GET /player/timeline/poll` and the body pushed to subscribers.
String buildTimelineXml(PlexCompanionTimeline timeline, {int? commandId}) {
  final active = timeline.isActive;
  final location = active ? (timeline.type == 'music' ? 'fullScreenMusic' : 'fullScreenVideo') : 'navigation';

  final out = StringBuffer(_xmlDeclaration);
  out.write('<MediaContainer');
  if (commandId != null) out.write(' commandID="$commandId"');
  out.write(' location="$location">');
  for (final type in const ['music', 'photo', 'video']) {
    if (active && type == timeline.type) {
      out.write('<Timeline ${_attributes(_activeTimelineAttributes(timeline))} />');
    } else {
      out.write('<Timeline type="$type" state="stopped" />');
    }
  }
  out.write('</MediaContainer>');
  return out.toString();
}

Map<String, String> _activeTimelineAttributes(PlexCompanionTimeline tl) {
  final durationMs = tl.duration.inMilliseconds;
  return <String, String>{
    'type': tl.type,
    'state': tl.state.wire,
    'time': '${tl.position.inMilliseconds}',
    'duration': '$durationMs',
    'seekRange': '0-$durationMs',
    'volume': '${tl.volume}',
    'controllable': _controllable,
    if (tl.machineIdentifier != null) 'machineIdentifier': tl.machineIdentifier!,
    if (tl.ratingKey != null) 'ratingKey': tl.ratingKey!,
    if (tl.key != null) 'key': tl.key!,
    if (tl.containerKey != null) 'containerKey': tl.containerKey!,
  };
}

String _attributes(Map<String, String> attrs) =>
    attrs.entries.map((e) => '${e.key}="${xmlEscapeAttribute(e.value)}"').join(' ');

// ---------------------------------------------------------------------------
// GDM ("Good Day Mate") discovery
// ---------------------------------------------------------------------------

/// Makes a value safe for a GDM header line.
///
/// python-plexapi parses replies with `line.split(':')` and unpacks exactly two
/// parts, so a value containing a colon raises and breaks Home Assistant's
/// whole scan - not only for this player. Newlines would forge extra headers.
String sanitizeGdmValue(String value) {
  final cleaned = value.replaceAll(RegExp(r'[\r\n]+'), ' ').replaceAll(':', '-').trim();
  return cleaned;
}

List<MapEntry<String, String>> _gdmHeaders(PlexCompanionDeviceInfo info, int port) => [
  const MapEntry('Content-Type', 'plex/media-player'),
  MapEntry('Resource-Identifier', sanitizeGdmValue(info.identifier)),
  MapEntry('Name', sanitizeGdmValue(info.name)),
  MapEntry('RawName', sanitizeGdmValue(info.name)),
  MapEntry('Port', '$port'),
  MapEntry('Product', sanitizeGdmValue(info.product)),
  MapEntry('Version', sanitizeGdmValue(info.version)),
  const MapEntry('Protocol', 'plex'),
  const MapEntry('Protocol-Version', '1'),
  MapEntry('Protocol-Capabilities', sanitizeGdmValue(info.capabilities)),
  MapEntry('Device-Class', sanitizeGdmValue(info.deviceClass)),
];

/// Header lines separated by plain `\n` with no trailing newline: the layout of
/// python plex-mpv-shim, a player Plex Media Server and python-plexapi are
/// known to accept. (An earlier version used `\r\n`; if a server kept the `\r`
/// as part of the identifier it would never match the player's sessions.)
String _gdmBody(PlexCompanionDeviceInfo info, int port) =>
    _gdmHeaders(info, port).map((e) => '${e.key}: ${e.value}').join('\n');

/// Unicast answer to an `M-SEARCH`. Must fit one 1024-byte datagram: that is
/// all python-plexapi reads.
String buildGdmSearchResponse(PlexCompanionDeviceInfo info, int port) =>
    'HTTP/1.0 200 OK\n${_gdmBody(info, port)}';

/// Registration announcement Plex Media Server turns into a `/clients` entry.
String buildGdmHello(PlexCompanionDeviceInfo info, int port) => 'HELLO * HTTP/1.0\n${_gdmBody(info, port)}';

/// De-registration sent on shutdown.
String buildGdmBye(PlexCompanionDeviceInfo info, int port) => 'BYE * HTTP/1.0\n${_gdmBody(info, port)}';

/// Whether a received datagram is a player search (`M-SEARCH * HTTP/1.0|1.1`).
bool isGdmSearch(String packet) => packet.trimLeft().startsWith('M-SEARCH * HTTP/1.');

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

/// Parses a number a controller sent as text and rounds it to an int.
///
/// Home Assistant's seek sends the position as a float (`offset=754000.0`), so
/// `int.tryParse` alone would reject every seek.
int? parseLenientInt(String? value) {
  if (value == null) return null;
  final parsed = num.tryParse(value.trim());
  if (parsed == null || !parsed.isFinite) return null;
  return parsed.round();
}

final RegExp _metadataKey = RegExp(r'^/library/metadata/(\d+)/?$');
final RegExp _playQueueKey = RegExp(r'^/playQueues/(\d+)');

/// The rating key of `/library/metadata/<id>`, or null for any other key
/// (playlists, shows, `/children` listings...).
String? ratingKeyFromMetadataKey(String? key) {
  if (key == null) return null;
  return _metadataKey.firstMatch(key)?.group(1);
}

/// The id of `/playQueues/<id>[?...]`, or null.
int? playQueueIdFromContainerKey(String? containerKey) {
  if (containerKey == null) return null;
  final match = _playQueueKey.firstMatch(containerKey);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Parses the query of `/player/playback/playMedia`. Throws
/// [PlexCompanionException] (400) when there is nothing to play.
PlexCompanionPlayMediaRequest parsePlayMediaQuery(Map<String, String> query) {
  final key = query['key'];
  final containerKey = query['containerKey'];
  if ((key == null || key.isEmpty) && (containerKey == null || containerKey.isEmpty)) {
    throw const PlexCompanionException(400, 'playMedia needs a key or containerKey');
  }
  final offsetMs = parseLenientInt(query['offset']) ?? 0;
  return PlexCompanionPlayMediaRequest(
    key: key ?? '',
    serverMachineIdentifier: query['machineIdentifier'],
    containerKey: containerKey,
    offset: Duration(milliseconds: offsetMs < 0 ? 0 : offsetMs),
    type: query['type'] ?? 'video',
    address: query['address'],
    port: parseLenientInt(query['port']),
    protocol: query['protocol'],
    token: query['token'],
  );
}
