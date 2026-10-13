import 'dart:async';

import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../mpv/mpv.dart';
import '../../services/plex_companion/plex_companion_types.dart';
import '../../services/video_volume_controller.dart';
import '../../utils/app_logger.dart';

/// Adapts the video player screen to [PlexCompanionPlayerControls] so Plex
/// Companion controllers (Home Assistant, Plex apps) can read its timeline and
/// drive it. Plain State-owned helper, like [CompanionRemoteBinding]: every
/// dependency is a late-bound getter or callback because the player is
/// re-created across playback attempts.
class PlexCompanionBinding implements PlexCompanionPlayerControls {
  PlexCompanionBinding({
    required this.player,
    required this.isMounted,
    required this.metadata,
    required this.canControlPlayback,
    required this.volumeController,
    required this.hasNextItem,
    required this.onPlay,
    required this.onPause,
    required this.onSeek,
    required this.onStop,
    required this.onNextItem,
    required this.onPreviousItem,
    required this.onSkipStep,
  });

  final Player? Function() player;
  final bool Function() isMounted;
  final MediaItem Function() metadata;
  final bool Function() canControlPlayback;
  final VideoVolumeController? Function() volumeController;
  final bool Function() hasNextItem;
  final Future<void> Function(Player player) onPlay;
  final Future<void> Function(Player player) onPause;
  final Future<void> Function(Duration position) onSeek;
  final Future<bool> Function() onStop;
  final Future<void> Function() onNextItem;
  final Future<void> Function() onPreviousItem;
  final void Function({required bool forward}) onSkipStep;

  bool get _usable => isMounted() && player() != null && canControlPlayback();

  @override
  PlexCompanionTimeline get timeline {
    final current = player();
    if (!isMounted() || current == null) return PlexCompanionTimeline.stopped;

    final s = current.state;
    final item = metadata();
    final isPlex = item.backend == MediaBackend.plex;

    final PlexCompanionState state;
    if (s.completed) {
      state = PlexCompanionState.stopped;
    } else if (s.buffering || (!s.playing && s.duration == Duration.zero)) {
      state = PlexCompanionState.buffering;
    } else if (s.playing) {
      state = PlexCompanionState.playing;
    } else {
      state = PlexCompanionState.paused;
    }
    if (state == PlexCompanionState.stopped) return PlexCompanionTimeline.stopped;

    return PlexCompanionTimeline(
      state: state,
      machineIdentifier: isPlex ? item.serverId : null,
      ratingKey: item.id,
      key: isPlex ? '/library/metadata/${item.id}' : null,
      position: s.position,
      duration: s.duration,
      volume: s.volume.isFinite ? s.volume.round().clamp(0, 100).toInt() : 100,
    );
  }

  @override
  Future<void> play() async {
    final current = player();
    if (_usable && current != null) await onPlay(current);
  }

  @override
  Future<void> pause() async {
    final current = player();
    if (_usable && current != null) await onPause(current);
  }

  @override
  Future<void> stop() async {
    if (!isMounted()) return;
    // Leaving the route can take a moment; the controller only needs the
    // command accepted.
    unawaited(
      onStop().then<void>(
        (_) {},
        onError: (Object e, StackTrace st) => appLogger.w('PlexCompanion: stop failed', error: e, stackTrace: st),
      ),
    );
  }

  @override
  Future<void> seekTo(Duration position) async {
    if (_usable) await onSeek(position);
  }

  @override
  Future<void> skipNext() async {
    if (isMounted() && canControlPlayback() && hasNextItem()) await onNextItem();
  }

  @override
  Future<void> skipPrevious() async {
    if (isMounted() && canControlPlayback()) await onPreviousItem();
  }

  @override
  Future<void> stepForward() async {
    if (_usable) onSkipStep(forward: true);
  }

  @override
  Future<void> stepBack() async {
    if (_usable) onSkipStep(forward: false);
  }

  @override
  Future<void> setVolume(int percent) async {
    final current = player();
    final controller = volumeController();
    if (!isMounted() || current == null || controller == null || !controller.ownsPlayer(current)) return;
    controller.commit(percent.clamp(0, 100).toDouble());
  }
}
