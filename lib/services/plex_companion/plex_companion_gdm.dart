import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'plex_companion_protocol.dart';
import 'plex_companion_types.dart';

typedef PlexCompanionLog = void Function(String message);

/// A socket bound to one local network address, with its listener.
class _InterfaceSocket {
  _InterfaceSocket({required this.adapter, required this.address, required this.socket, required this.subscription});

  final String adapter;
  final InternetAddress address;
  final RawDatagramSocket socket;
  final StreamSubscription<RawSocketEvent> subscription;

  Future<void> close() async {
    await subscription.cancel();
    socket.close();
  }
}

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
/// The announcement is sent FROM a socket that can also answer searches, like
/// the proven python plex-mpv-shim player does. Plex Media Server verifies a
/// registration by sending a search back to the announcer, so the announcement
/// has to come from a socket that is listening and can answer it.
///
/// Android: a socket bound to 0.0.0.0 sends broadcast and multicast packets out
/// whichever network the system picks, which on a phone with mobile data is often
/// not the Wi-Fi. Announcements would then never reach the Plex server and the
/// player would be missing from Home Assistant while idle. So on Android one
/// socket is bound per Wi-Fi/Ethernet address (the same approach Plezy's own LAN
/// discovery uses), which pins the network the packets leave from.
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

  /// Android only: one socket per Wi-Fi/Ethernet address, keyed by address.
  final Map<String, _InterfaceSocket> _interfaceSockets = {};
  bool _refreshingInterfaces = false;

  Timer? _helloTimer;
  Timer? _retryTimer;
  bool _running = false;
  bool _binding = false;
  int _searchesAnswered = 0;
  final Map<String, DateTime> _lastSearchLog = {};

  bool get isListening => _listener != null;

  /// How many player searches have been answered since start.
  int get searchesAnswered => _searchesAnswered;

  bool get _usesInterfaceSockets => Platform.isAndroid;

  Future<void> start() async {
    if (_running) return;
    _running = true;

    if (!await _bindListener()) {
      await _openFallback();
      _retryTimer = Timer.periodic(listenerRetryInterval, (_) => _retryListener());
    }

    await _refreshInterfaceSockets();
    _announce(buildGdmHello(info, httpPort));
    _helloTimer = Timer.periodic(helloInterval, (_) async {
      await _refreshInterfaceSockets();
      _announce(buildGdmHello(info, httpPort));
    });
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
    for (final entry in _interfaceSockets.values.toList()) {
      await entry.close();
    }
    _interfaceSockets.clear();
  }

  /// Binds with progressively more tolerant options. Some platforms (some
  /// Android builds, for one) reject SO_REUSEPORT, so a failure there must not
  /// leave the player undiscoverable.
  Future<RawDatagramSocket> _bindTolerant(InternetAddress address, int port) async {
    final attempts = <({bool reuseAddress, bool reusePort})>[
      if (!Platform.isWindows) (reuseAddress: true, reusePort: true),
      (reuseAddress: true, reusePort: false),
    ];
    Object? lastError;
    for (final attempt in attempts) {
      try {
        return await RawDatagramSocket.bind(
          address,
          port,
          reuseAddress: attempt.reuseAddress,
          reusePort: attempt.reusePort,
        );
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? StateError('could not bind');
  }

  /// Binds the search listener. Returns whether it is now listening.
  Future<bool> _bindListener() async {
    if (_listener != null) return true;
    if (_binding) return false;
    _binding = true;
    try {
      final socket = await _bindTolerant(InternetAddress.anyIPv4, playerPort);
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
        'player while idle. Another app on this device (Plex Media Server, Plex HTPC, Plexamp) '
        'may own the port. Retrying every ${listenerRetryInterval.inSeconds} s.',
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

  // ---------------------------------------------------------------------------
  // Android: one announcement socket per Wi-Fi / Ethernet address
  // ---------------------------------------------------------------------------

  /// Adapters that are mobile data, VPNs or virtual links: never announce there.
  static bool _isLanAdapterName(String name) {
    final lower = name.toLowerCase();
    if (lower == 'lo') return false;
    const skipPrefixes = ['rmnet', 'ccmni', 'tun', 'ppp', 'pdp', 'wwan', 'dummy', 'p2p', 'v4-', 'ipsec', 'clat'];
    for (final prefix in skipPrefixes) {
      if (lower.startsWith(prefix)) return false;
    }
    return true;
  }

  /// 10/8, 172.16/12 and 192.168/16. Carrier-grade NAT (100.64/10) is mobile data.
  static bool _isPrivateLan(InternetAddress address) {
    final raw = address.rawAddress;
    if (raw.length != 4) return false;
    if (raw[0] == 10) return true;
    if (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) return true;
    if (raw[0] == 192 && raw[1] == 168) return true;
    return false;
  }

  /// The "a.b.c.255" address of a typical /24 home network.
  static InternetAddress _directedBroadcast(InternetAddress address) {
    final raw = address.rawAddress;
    return InternetAddress.fromRawAddress(Uint8List.fromList([raw[0], raw[1], raw[2], 255]));
  }

  /// Keeps [_interfaceSockets] in step with the device's current Wi-Fi or
  /// Ethernet addresses (they change when the phone joins another network).
  Future<void> _refreshInterfaceSockets() async {
    if (!_usesInterfaceSockets || !_running || _refreshingInterfaces) return;
    _refreshingInterfaces = true;
    try {
      final wanted = <String, ({String adapter, InternetAddress address})>{};
      try {
        final adapters = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
          includeLinkLocal: false,
        );
        for (final adapter in adapters) {
          if (!_isLanAdapterName(adapter.name)) continue;
          for (final address in adapter.addresses) {
            if (_isPrivateLan(address)) wanted[address.address] = (adapter: adapter.name, address: address);
          }
        }
      } catch (e) {
        _log('GDM: could not list network adapters: $e');
        return;
      }

      for (final key in _interfaceSockets.keys.toList()) {
        if (!wanted.containsKey(key)) {
          final gone = _interfaceSockets.remove(key);
          if (gone != null) {
            _log('GDM: network address $key (${gone.adapter}) is gone');
            await gone.close();
          }
        }
      }

      for (final entry in wanted.entries) {
        if (_interfaceSockets.containsKey(entry.key) || !_running) continue;
        final socket = await _bindForInterface(entry.value.address);
        if (socket == null) continue;
        _interfaceSockets[entry.key] = _InterfaceSocket(
          adapter: entry.value.adapter,
          address: entry.value.address,
          socket: socket,
          subscription: socket.listen(
            (event) => _onEvent(socket, event),
            onError: (Object e) => _log('GDM: socket error on ${entry.key}: $e'),
          ),
        );
        _log('GDM: announcing from ${entry.key} (${entry.value.adapter}), local port ${socket.port}');
      }

      if (_interfaceSockets.isEmpty) {
        _log(
          'GDM: no Wi-Fi/Ethernet address found to announce from; '
          'using the default network instead (it may be mobile data)',
        );
      }
    } finally {
      _refreshingInterfaces = false;
    }
  }

  /// Prefers port 32412, like the proven working player, and falls back to a
  /// random port if that is taken.
  Future<RawDatagramSocket?> _bindForInterface(InternetAddress address) async {
    try {
      final socket = await _bindTolerant(address, playerPort);
      socket.broadcastEnabled = true;
      return socket;
    } catch (_) {
      // fall through to a random port
    }
    try {
      final socket = await RawDatagramSocket.bind(address, 0);
      socket.broadcastEnabled = true;
      return socket;
    } catch (e) {
      _log('GDM: could not open a socket on ${address.address}: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Announcing and answering
  // ---------------------------------------------------------------------------

  void _announce(String message) {
    final bytes = utf8.encode(message);
    if (_interfaceSockets.isNotEmpty) {
      for (final entry in _interfaceSockets.values) {
        _sendAnnouncement(entry.socket, bytes, entry.address);
      }
      return;
    }
    final socket = _listener ?? _fallback;
    if (socket == null) return;
    _sendAnnouncement(socket, bytes, null);
  }

  void _sendAnnouncement(RawDatagramSocket socket, List<int> bytes, InternetAddress? local) {
    final targets = <InternetAddress>[
      InternetAddress('239.0.0.250'),
      InternetAddress('255.255.255.255'),
      if (local != null) _directedBroadcast(local),
    ];
    for (final target in targets) {
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
