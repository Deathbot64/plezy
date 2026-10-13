/// Shared types for the Plex Companion ("remote control") implementation.
///
/// Plex Companion is the LAN protocol Plex clients use to be driven by other
/// Plex apps and by Home Assistant's Plex integration (python-plexapi). This
/// file deliberately depends only on `dart:core` so the protocol layer can be
/// unit-tested without Flutter.
library;

/// Playback state as exposed on the Companion timeline.
enum PlexCompanionState {
  stopped('stopped'),
  paused('paused'),
  playing('playing'),
  buffering('buffering');

  const PlexCompanionState(this.wire);

  /// The value written into the `state` attribute of a `<Timeline>`.
  final String wire;
}

/// An immutable snapshot of what the player is doing right now.
class PlexCompanionTimeline {
  const PlexCompanionTimeline({
    this.state = PlexCompanionState.stopped,
    this.type = 'video',
    this.machineIdentifier,
    this.ratingKey,
    this.key,
    this.containerKey,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 100,
  });

  /// Nothing is playing.
  static const PlexCompanionTimeline stopped = PlexCompanionTimeline();

  final PlexCompanionState state;

  /// `video`, `music` or `photo`.
  final String type;

  /// Machine identifier of the Plex server that owns the item.
  final String? machineIdentifier;
  final String? ratingKey;

  /// e.g. `/library/metadata/123`.
  final String? key;

  /// The play queue / container the item was launched from, if any.
  final String? containerKey;

  final Duration position;
  final Duration duration;

  /// 0..100 (the Plex scale).
  final int volume;

  bool get isActive => state != PlexCompanionState.stopped;

  /// Whether two snapshots differ in a way a long-polling controller should be
  /// told about immediately (position drift alone is not one).
  bool differsMeaningfullyFrom(PlexCompanionTimeline other) {
    return state != other.state || ratingKey != other.ratingKey || volume != other.volume || type != other.type;
  }
}

/// What the player is called on the network and what it can do.
class PlexCompanionDeviceInfo {
  const PlexCompanionDeviceInfo({
    required this.identifier,
    required this.name,
    this.product = 'Plezy',
    this.platform = '',
    this.platformVersion = '',
    this.version = '',
    this.deviceClass = 'pc',
    this.capabilities = 'timeline,playback,navigation',
  });

  /// Must equal the `X-Plex-Client-Identifier` Plezy uses towards the server,
  /// so Plex Media Server sessions and Companion discovery refer to the same
  /// player (Home Assistant joins them on this value).
  final String identifier;
  final String name;
  final String product;
  final String platform;
  final String platformVersion;
  final String version;

  /// `pc`, `stb` or `phone`.
  final String deviceClass;

  /// Comma separated Companion controllers this player implements.
  final String capabilities;
}

/// A `/player/playback/playMedia` request, already parsed.
class PlexCompanionPlayMediaRequest {
  const PlexCompanionPlayMediaRequest({
    required this.key,
    this.serverMachineIdentifier,
    this.containerKey,
    this.offset = Duration.zero,
    this.type = 'video',
    this.address,
    this.port,
    this.protocol,
    this.token,
  });

  /// Item key, e.g. `/library/metadata/123`.
  final String key;

  /// Machine identifier of the Plex server hosting the item.
  final String? serverMachineIdentifier;

  /// e.g. `/playQueues/42?window=100&own=1`.
  final String? containerKey;

  final Duration offset;
  final String type;

  /// Server connection hints sent by the controller. Plezy resolves the
  /// server from its own signed-in accounts instead, so [token] is never used.
  final String? address;
  final int? port;
  final String? protocol;
  final String? token;
}

/// UI navigation commands from `/player/navigation/*`.
enum PlexCompanionNavigation { up, down, left, right, select, back, home, contextMenu }

/// Raised by a host to turn a failure into an HTTP status for the controller.
class PlexCompanionException implements Exception {
  const PlexCompanionException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'PlexCompanionException($statusCode): $message';
}

/// The slice of the video player a Companion controller may drive.
abstract interface class PlexCompanionPlayerControls {
  PlexCompanionTimeline get timeline;

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seekTo(Duration position);
  Future<void> skipNext();
  Future<void> skipPrevious();
  Future<void> stepForward();
  Future<void> stepBack();

  /// [percent] is on the Plex 0..100 scale.
  Future<void> setVolume(int percent);
}

/// The application side of the Companion server.
abstract interface class PlexCompanionHost {
  /// The player currently on screen, or null when idle.
  PlexCompanionPlayerControls? get activePlayer;

  /// Start playback. Implementations validate and resolve the request, then
  /// return once playback has been *accepted*; they throw
  /// [PlexCompanionException] with a meaningful status when it cannot start.
  Future<void> playMedia(PlexCompanionPlayMediaRequest request);

  /// Returns false when nothing could act on the command.
  bool navigate(PlexCompanionNavigation action);
}
