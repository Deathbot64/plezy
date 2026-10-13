import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../navigation/profile_navigation_scope.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/app_logger.dart';
import '../../utils/video_player_navigation.dart';
import '../driver_distraction.dart';
import '../playback_coordinator.dart';
import '../plex_client.dart';
import 'plex_companion_protocol.dart';
import 'plex_companion_types.dart';

/// Starts playback for a Companion `playMedia` request through the same
/// navigation path the UI uses.
///
/// Resolves the server from Plezy's own signed-in accounts (by machine
/// identifier) rather than using the controller-supplied address/token, so it
/// never has to trust or store a transient token. Completes when playback has
/// been accepted; throws [PlexCompanionException] otherwise.
Future<void> launchPlexCompanionPlayback(PlexCompanionPlayMediaRequest request) async {
  BuildContext? currentContext() => profileNavigationRegistry.navigator?.overlay?.context;

  var context = currentContext();
  if (context == null || !context.mounted) {
    throw const PlexCompanionException(503, 'Plezy has no active profile session');
  }
  if (!automotivePlaybackAllowedNow()) {
    throw const PlexCompanionException(403, 'Playback is restricted right now');
  }
  if (request.type != 'video') {
    throw const PlexCompanionException(415, 'Only video playback is supported');
  }

  final servers = Provider.of<MultiServerProvider>(context, listen: false);
  final machineId = request.serverMachineIdentifier;
  final PlexClient? client = machineId == null ? null : servers.getPlexClientForServer(ServerId(machineId));
  if (client == null) {
    throw PlexCompanionException(404, 'Plex server ${machineId ?? '(unspecified)'} is not available in Plezy');
  }

  MediaItem? item;
  final ratingKey = ratingKeyFromMetadataKey(request.key);
  if (ratingKey != null) {
    item = await client.fetchItem(ratingKey);
  } else {
    // Playlists, shows and the like arrive as a play queue; start from its
    // selected (or first) item.
    final queueId = playQueueIdFromContainerKey(request.containerKey);
    if (queueId != null) {
      final queue = await client.getPlayQueue(queueId);
      item = queue?.selectedItem ?? queue?.items?.firstOrNull;
    }
  }
  if (item == null) throw const PlexCompanionException(404, 'Item not found on the server');
  if (!item.kind.isPlayable || item.kind == MediaKind.track) {
    throw const PlexCompanionException(415, 'That item is not playable video');
  }

  // A new request replaces whatever is playing.
  final coordinator = PlaybackCoordinator.instance;
  if (coordinator.hasVideoSession) {
    final exited = await coordinator.stopVideoAndExit();
    if (!exited) throw const PlexCompanionException(409, 'The current player cannot be closed remotely');
    await WidgetsBinding.instance.endOfFrame;
  }

  context = currentContext();
  if (context == null || !context.mounted) {
    throw const PlexCompanionException(503, 'Plezy has no active profile session');
  }

  // Plex semantics: `offset` is the explicit start position (0 = beginning).
  unawaited(
    navigateToVideoPlayer(context, metadata: item, initialPosition: request.offset).then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        appLogger.w('PlexCompanion: playback launch failed', error: error, stackTrace: stackTrace);
      },
    ),
  );
}
