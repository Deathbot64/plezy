import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'plex_companion_protocol.dart';
import 'plex_companion_types.dart';

typedef PlexCompanionLog = void Function(String message);

/// GDM ("Good Day Mate") discovery for a Plex player.
///
/// * Answers `M-SEARCH` datagrams on UDP 32412. This is how Home Assistant
///   (python-plexapi's `GDM.scan(scan_for_clients=True)`) and Plex's own apps
///   find players on the LAN: they broadcast the search and read the unicast
///   reply, taking the player's address from the datagram's source. It is what
///   lets Home Assistant list this player while nothing is playing.
/// * Announces itself with `HELLO` to UDP 32413 so Plex Media Server lists the
///   player under `/clients`, and says `BYE` when it stops.
///
/// The announcement is sent FROM the same socket that listens on 32412, like
/// the proven python plex-mpv-shim player does. Plex Media Server verifies a
/// registration by sending a search back to the announcer, so the announcement
/// has to come from a socket that is listening and can answer it. (An earlier
/// version announced from a random port nobody listened on, which a server can
/// fail to verify.)
///
/// Failing to bind 32412 (for example another Plex app on the same machine
/// owns it) is not fatal: the HTTP side keeps working, the problem is logged
/// prominently, announcements fall back to a socket that also answers
/// searches, and binding is retried every minute.
class PlexCompanionGdm {
  PlexCompanionGdm({required this.info, required this.httpPort, PlexCompanionLog? log}) : _log = log ?? _ignore;

  static void _ignore(String _) {}

  /// Players listen here for searches.
  static const int playerPort = 32412;

  /// Servers listen here for player registrations.
  static const int registrationPort = 32413;

  static const Duration helloInterval = Duration(seconds: 30);
  static const Duration listenerRetryInterval = Duration(seconds: 60);

  /// A given searcher is logged at most this often, so a scanner that asks
  /// every few seconds does not flood the log.
  static const Duration _searchLogInterval = Duration(minutes: 10);

  final PlexCompanionDeviceInfo info;

  /// The port of the Companion HTTP server advertised to controllers.
  final int httpPort;

  final PlexCompanionLog _log;

  RawDatagramSocket? _listener;
  StreamSubscription<RawSocketEvent>? _listenerSubscription;

  /// Fallback used only while [_listener] could not be bound.
  RawDatagramSocket? _fallback;
  StreamSubscription<RawSocketEvent>? _fallbackSubscription;

  Timer? _helloTimer;
  Timer? _retryTimer;
  bool _running = false;
  bool _binding = false;
  int _searchesAnswered = 0;
  final Map<String, DateTime> _lastSearchLog = {};

  bool get isListening => _listener != null;

  /// How many player searches have been answered since start.
  int get searchesAnswered => _searchesAnswered;

  Future<void> start() async {
    if (_running) return;
    _running = true;

    if (!await _bindListener()) {
      await _openFallback();
      _retryTimer = Timer.periodic(listenerRetryInterval, (_) => _retryListener());
    }

    _announce(buildGdmHello(info, httpPort));
    _helloTimer = Timer.periodic(helloInterval, (_) => _announce(buildGdmHello(info, httpPort)));
    _log('GDM: announcing this player to Plex Media Server (HELLO to UDP $registrationPort) every 30 s');
  }

  Future<void> stop() async {
    _running = false;
    _helloTimer?.cancel();
    _helloTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;

    _announce(buildGdmBye(info, httpPort));

    await _listenerSubscription?.cancel();
    _listenerSubscription = null;
    _listener?.close();
    _listener = null;
    await _closeFallback();
  }

  /// Binds the search listener. Returns whether it is now listening.
  Future<bool> _bindListener() async {
    if (_listener != null) return true;
    if (_binding) return false;
    _binding = true;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        playerPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      if (!_running) {
        socket.close();
        return false;
      }
      socket.broadcastEnabled = true;
      try {
        socket.joinMulticast(InternetAddress('239.0.0.250'));
      } catch (e) {
        // Broadcast searches (what Home Assistant sends) still arrive.
        _log('GDM: could not join the multicast group (broadcast searches still work): $e');
      }
      _listener = socket;
      _listenerSubscription = socket.listen(
        (event) => _onEvent(socket, event),
        onError: (Object e) => _log('GDM: listener error: $e'),
      );
      _log('GDM: listening for player searches on UDP $playerPort');
      return true;
    } catch (e) {
      _log(
        'GDM: CANNOT listen on UDP $playerPort ($e). Home Assistant will not find this '
        'player while idle. Another Plex app on this computer (Plex Media Server, Plex HTPC) '
        'probably owns the port. Retrying every ${listenerRetryInterval.inSeconds} s.',
      );
      return false;
    } finally {
      _binding = false;
    }
  }

  /// A random-port socket used for announcements while 32412 is unavailable.
  /// It also answers searches sent to it, because a server verifies an
  /// announcement by searching the address it came from.
  Future<void> _openFallback() async {
    if (_fallback != null) return;
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      _fallback = socket;
      _fallbackSubscription = socket.listen(
        (event) => _onEvent(socket, event),
        onError: (Object e) => _log('GDM: fallback socket error: $e'),
      );
    } catch (e) {
      _log('GDM: could not open the announcement socket: $e');
    }
  }

  Future<void> _closeFallback() async {
    await _fallbackSubscription?.cancel();
    _fallbackSubscription = null;
    _fallback?.close();
    _fallback = null;
  }

  Future<void> _retryListener() async {
    if (!_running || _listener != null) {
      _retryTimer?.cancel();
      _retryTimer = null;
      return;
    }
    if (await _bindListener()) {
      _retryTimer?.cancel();
      _retryTimer = null;
      await _closeFallback();
      // Re-announce from the proper socket right away.
      _announce(buildGdmHello(info, httpPort));
    }
  }

  void _announce(String message) {
    final socket = _listener ?? _fallback;
    if (socket == null) return;
    final bytes = utf8.encode(message);
    for (final target in [InternetAddress('239.0.0.250'), InternetAddress('255.255.255.255')]) {
      try {
        socket.send(bytes, target, registrationPort);
      } catch (e) {
        _log('GDM: announce to ${target.address} failed: $e');
      }
    }
  }

  void _onEvent(RawDatagramSocket socket, RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      _handleDatagram(socket, datagram!);
    }
  }

  void _handleDatagram(RawDatagramSocket socket, Datagram datagram) {
    final String packet;
    try {
      packet = utf8.decode(datagram.data, allowMalformed: true);
    } catch (_) {
      return;
    }
    if (!isGdmSearch(packet)) return;
    try {
      socket.send(utf8.encode(buildGdmSearchResponse(info, httpPort)), datagram.address, datagram.port);
    } catch (e) {
      _log('GDM: reply to ${datagram.address.address} failed: $e');
      return;
    }
    _searchesAnswered++;
    final from = datagram.address.address;
    final now = DateTime.now();
    final last = _lastSearchLog[from];
    if (last == null || now.difference(last) > _searchLogInterval) {
      _lastSearchLog[from] = now;
      _log('GDM: answered a player search from $from (searches answered so far: $_searchesAnswered)');
    }
  }
}
