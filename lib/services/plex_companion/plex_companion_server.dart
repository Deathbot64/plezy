import 'dart:async';
import 'dart:io';

import 'plex_companion_gdm.dart' show PlexCompanionLog;
import 'plex_companion_protocol.dart';
import 'plex_companion_types.dart';

class _Subscriber {
  _Subscriber({required this.host, required this.port, required this.protocol, required this.commandId})
    : lastSeen = DateTime.now();

  final String host;
  final int port;
  final String protocol;
  int commandId;
  DateTime lastSeen;
  int failures = 0;
}

/// The HTTP half of Plex Companion: the endpoints a controller (Home
/// Assistant, Plex mobile apps, Plex Web) calls on a player.
class PlexCompanionServer {
  PlexCompanionServer({required this.host, required this.info, PlexCompanionLog? log}) : _log = log ?? _ignore;

  static void _ignore(String _) {}

  static const int defaultPort = 32500;
  static const Duration _subscriberTtl = Duration(seconds: 90);
  static const Duration _maxLongPoll = Duration(seconds: 30);

  final PlexCompanionHost host;
  final PlexCompanionDeviceInfo info;
  final PlexCompanionLog _log;

  HttpServer? _http;
  HttpClient? _pushClient;
  Timer? _ticker;
  final Map<String, _Subscriber> _subscribers = {};

  bool get isRunning => _http != null;

  /// The port actually bound (differs from the preferred one on a clash).
  int get port => _http?.port ?? 0;

  Future<int> start({int preferredPort = defaultPort}) async {
    if (_http != null) return _http!.port;
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
    } on SocketException catch (e) {
      _log('Companion: port $preferredPort unavailable ($e); using a free port');
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _http = server;
    server.listen(_onRequest, onError: (Object e) => _log('Companion: server error: $e'));
    _log('Companion: listening on TCP ${server.port}');
    return server.port;
  }

  Future<void> stop() async {
    _ticker?.cancel();
    _ticker = null;
    _subscribers.clear();
    final server = _http;
    _http = null;
    await server?.close(force: true);
    _pushClient?.close(force: true);
    _pushClient = null;
  }

  // -------------------------------------------------------------------------
  // Request handling
  // -------------------------------------------------------------------------

  Future<void> _onRequest(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set('X-Plex-Client-Identifier', info.identifier)
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Expose-Headers', 'X-Plex-Client-Identifier')
      ..contentType = ContentType('text', 'xml', charset: 'utf-8');

    var status = 200;
    String body = '';
    try {
      if (req.method == 'OPTIONS') {
        res.headers
          ..set('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, HEAD, OPTIONS')
          ..set('Access-Control-Max-Age', '1209600')
          ..set(
            'Access-Control-Allow-Headers',
            'accept, content-type, x-plex-token, x-plex-client-identifier, x-plex-target-client-identifier, '
                'x-plex-device-name, x-plex-device, x-plex-platform, x-plex-platform-version, x-plex-product, '
                'x-plex-version, x-plex-provides, x-plex-username, x-plex-language',
          );
      } else {
        body = await _route(req);
      }
    } on PlexCompanionException catch (e) {
      status = e.statusCode;
      body = buildErrorResponseXml(e.statusCode, e.message);
      _log('Companion: ${req.uri.path} -> ${e.statusCode} ${e.message}');
    } catch (e) {
      status = 500;
      body = buildErrorResponseXml(500, 'Internal error');
      _log('Companion: ${req.uri.path} failed: $e');
    }

    try {
      res.statusCode = status;
      res.write(body);
      await res.close();
    } catch (_) {
      // Controller hung up; nothing to do.
    }
  }

  Future<String> _route(HttpRequest req) async {
    var path = req.uri.path;
    if (path.length > 1 && path.endsWith('/')) path = path.substring(0, path.length - 1);
    final query = req.uri.queryParameters;
    final controllerId = req.headers.value('x-plex-client-identifier');

    switch (path) {
      case '/':
        return buildOkResponseXml();
      case '/resources':
        return buildResourcesXml(info);
      case '/player/timeline/poll':
        return _poll(query);
      case '/player/timeline/subscribe':
        return _subscribe(req, query, controllerId);
      case '/player/timeline/unsubscribe':
        _subscribers.remove(_subscriberKey(req, controllerId));
        _stopTickerIfIdle();
        return buildOkResponseXml();
      case '/player/mirror/details':
        return buildOkResponseXml();
    }
    if (path.startsWith('/player/playback/')) {
      return _playback(path.substring('/player/playback/'.length), query);
    }
    if (path.startsWith('/player/navigation/')) {
      return _navigation(path.substring('/player/navigation/'.length));
    }
    if (path.startsWith('/player/application/')) return buildOkResponseXml();
    throw const PlexCompanionException(404, 'Unknown command');
  }

  PlexCompanionTimeline get _timeline => host.activePlayer?.timeline ?? PlexCompanionTimeline.stopped;

  // -------------------------------------------------------------------------
  // Timeline
  // -------------------------------------------------------------------------

  Future<String> _poll(Map<String, String> query) async {
    final commandId = int.tryParse(query['commandID'] ?? '');
    if (query['wait'] == '1') await _waitForChange();
    return buildTimelineXml(_timeline, commandId: commandId);
  }

  Future<void> _waitForChange() async {
    final baseline = _timeline;
    final deadline = DateTime.now().add(_maxLongPoll);
    while (isRunning && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_timeline.differsMeaningfullyFrom(baseline)) return;
    }
  }

  String _subscriberKey(HttpRequest req, String? controllerId) =>
      controllerId ?? req.connectionInfo?.remoteAddress.address ?? 'unknown';

  String _subscribe(HttpRequest req, Map<String, String> query, String? controllerId) {
    final address = req.connectionInfo?.remoteAddress.address;
    if (address == null) throw const PlexCompanionException(400, 'Unknown subscriber address');
    final commandId = int.tryParse(query['commandID'] ?? '') ?? 0;
    final key = _subscriberKey(req, controllerId);
    final existing = _subscribers[key];
    if (existing != null) {
      existing.commandId = commandId;
      existing.lastSeen = DateTime.now();
    } else {
      _subscribers[key] = _Subscriber(
        host: address,
        port: int.tryParse(query['port'] ?? '') ?? defaultPort,
        protocol: query['protocol'] == 'https' ? 'https' : 'http',
        commandId: commandId,
      );
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    return buildTimelineXml(_timeline, commandId: commandId);
  }

  void _tick() {
    final now = DateTime.now();
    _subscribers.removeWhere((_, s) => now.difference(s.lastSeen) > _subscriberTtl || s.failures >= 3);
    if (_stopTickerIfIdle()) return;
    for (final sub in _subscribers.values) {
      _push(sub, buildTimelineXml(_timeline, commandId: sub.commandId));
    }
  }

  bool _stopTickerIfIdle() {
    if (_subscribers.isNotEmpty) return false;
    _ticker?.cancel();
    _ticker = null;
    return true;
  }

  Future<void> _push(_Subscriber sub, String xml) async {
    try {
      var client = _pushClient;
      if (client == null) {
        client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 2);
        _pushClient = client;
      }
      final request = await client.postUrl(Uri.parse('${sub.protocol}://${sub.host}:${sub.port}/:/timeline'));
      request.headers
        ..set('X-Plex-Client-Identifier', info.identifier)
        ..set('X-Plex-Device-Name', info.name)
        ..set('X-Plex-Product', info.product)
        ..contentType = ContentType('text', 'xml', charset: 'utf-8');
      request.write(xml);
      final response = await request.close().timeout(const Duration(seconds: 3));
      await response.drain<void>();
      sub.failures = 0;
    } catch (_) {
      sub.failures++;
    }
  }

  // -------------------------------------------------------------------------
  // Commands
  // -------------------------------------------------------------------------

  Future<String> _playback(String command, Map<String, String> query) async {
    if (command == 'playMedia') {
      await host.playMedia(parsePlayMediaQuery(query));
      return buildOkResponseXml();
    }

    // Like Plex's own players, accept transport commands even when idle.
    final player = host.activePlayer;
    switch (command) {
      case 'play':
        await player?.play();
      case 'pause':
        await player?.pause();
      case 'stop':
        await player?.stop();
      case 'skipNext':
        await player?.skipNext();
      case 'skipPrevious':
        await player?.skipPrevious();
      case 'stepForward':
        await player?.stepForward();
      case 'stepBack':
        await player?.stepBack();
      case 'seekTo':
        final ms = parseLenientInt(query['offset']);
        if (ms == null) throw const PlexCompanionException(400, 'seekTo needs an offset');
        await player?.seekTo(Duration(milliseconds: ms < 0 ? 0 : ms));
      case 'setParameters':
        final volume = parseLenientInt(query['volume']);
        if (volume != null) await player?.setVolume(volume.clamp(0, 100).toInt());
      case 'setStreams' || 'setRepeat' || 'setShuffle' || 'refreshPlayQueue' || 'skipTo':
        break; // accepted, not supported
      default:
        throw const PlexCompanionException(404, 'Unknown playback command');
    }
    return buildOkResponseXml();
  }

  String _navigation(String command) {
    final action = switch (command) {
      'moveUp' => PlexCompanionNavigation.up,
      'moveDown' => PlexCompanionNavigation.down,
      'moveLeft' => PlexCompanionNavigation.left,
      'moveRight' => PlexCompanionNavigation.right,
      'select' => PlexCompanionNavigation.select,
      'back' => PlexCompanionNavigation.back,
      'home' => PlexCompanionNavigation.home,
      'contextMenu' => PlexCompanionNavigation.contextMenu,
      _ => null,
    };
    if (action != null) host.navigate(action);
    return buildOkResponseXml();
  }
}
