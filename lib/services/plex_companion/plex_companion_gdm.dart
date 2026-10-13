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
///   reply, taking the player's address from the datagram's source.
/// * Announces itself with `HELLO` to UDP 32413 so Plex Media Server lists the
///   player under `/clients`, and says `BYE` when it stops.
///
/// Failing to bind 32412 (for example another Plex app on the same machine
/// owns it) is not fatal: the HTTP side keeps working and the problem is
/// logged.
class PlexCompanionGdm {
  PlexCompanionGdm({required this.info, required this.httpPort, PlexCompanionLog? log}) : _log = log ?? _ignore;

  static void _ignore(String _) {}

  /// Players listen here for searches.
  static const int playerPort = 32412;

  /// Servers listen here for player registrations.
  static const int registrationPort = 32413;

  static const Duration helloInterval = Duration(seconds: 30);

  final PlexCompanionDeviceInfo info;

  /// The port of the Companion HTTP server advertised to controllers.
  final int httpPort;

  final PlexCompanionLog _log;

  RawDatagramSocket? _listener;
  RawDatagramSocket? _sender;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _helloTimer;

  bool get isListening => _listener != null;

  Future<void> start() async {
    if (_listener != null || _sender != null) return;

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        playerPort,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      socket.broadcastEnabled = true;
      try {
        socket.joinMulticast(InternetAddress('239.0.0.250'));
      } catch (e) {
        // Broadcast searches (what Home Assistant sends) still arrive.
        _log('GDM: could not join multicast group: $e');
      }
      _listener = socket;
      _subscription = socket.listen(
        _onEvent,
        onError: (Object e) => _log('GDM: listener error: $e'),
      );
      _log('GDM: answering player searches on UDP $playerPort');
    } catch (e) {
      _log(
        'GDM: could not listen on UDP $playerPort ($e). Discovery by scan will not '
        'work; another Plex app on this machine may own the port.',
      );
    }

    try {
      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sender.broadcastEnabled = true;
      _sender = sender;
      _announce(buildGdmHello(info, httpPort));
      _helloTimer = Timer.periodic(helloInterval, (_) => _announce(buildGdmHello(info, httpPort)));
    } catch (e) {
      _log('GDM: could not open announcement socket: $e');
    }
  }

  Future<void> stop() async {
    _helloTimer?.cancel();
    _helloTimer = null;

    if (_sender != null) _announce(buildGdmBye(info, httpPort));

    await _subscription?.cancel();
    _subscription = null;
    _listener?.close();
    _listener = null;
    _sender?.close();
    _sender = null;
  }

  void _announce(String message) {
    final sender = _sender;
    if (sender == null) return;
    final bytes = utf8.encode(message);
    for (final target in [InternetAddress('239.0.0.250'), InternetAddress('255.255.255.255')]) {
      try {
        sender.send(bytes, target, registrationPort);
      } catch (e) {
        _log('GDM: announce to ${target.address} failed: $e');
      }
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _listener;
    if (socket == null) return;
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
    }
  }
}
