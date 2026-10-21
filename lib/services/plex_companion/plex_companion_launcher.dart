import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../media/ids.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../models/plex/play_queue_response.dart';
import '../../navigation/profile_navigation_scope.dart';
import '../../providers/multi_server_provider.dart';
import '../../providers/playback_state_provider.dart';
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
///
/// Play queues: for shuffle, playlists, seasons and other multi-item requests
/// Home Assistant creates a Plex play queue and sends the first item plus the
/// queue's id (`containerKey=/playQueues/<id>`). When that queue holds more
/// than one item it is published to [PlaybackStateProvider] and the player
/// opens the queue's own item, exactly like Plezy's built-in Shuffle button, so
/// next/previous follow the queue's order. Without that, the player would
/// ignore the queue and walk the show's episodes in order instead.
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

  // The play queue the controller created, if any.
  PlayQueueResponse? queue;
  final queueId = playQueueIdFromContainerKey(request.containerKey);
  if (queueId != null) {
    try {
      queue = await client.getPlayQueue(queueId);
    } catch (e, stackTrace) {
      appLogger.w(
        'PlexCompanion: could not read play queue $queueId; playing the single item',
        error: e,
        stackTrace: stackTrace,
      );
    }
    if (queue == null) {
      appLogger.w('PlexCompanion: play queue $queueId was not available; playing the single item');
    }
  }

  final ratingKey = ratingKeyFromMetadataKey(request.key);
  MediaItem? item;

  // Which queue (if any) the player should follow. Only multi-item queues are
  // followed: a single episode keeps Plezy's normal "continue with the next
  // episode of the season" behaviour.
  PlayQueueResponse? followQueue;
  final queueItems = queue?.items;
  if (queue != null && queueItems != null && queueItems.isNotEmpty) {
    MediaItem? match;
    if (ratingKey != null) {
      for (final candidate in queueItems) {
        if (candidate.id == ratingKey) {
          match = candidate;
          break;
        }
      }
    }
    final total = queue.playQueueTotalCount ?? queue.size ?? queueItems.length;
    if (match != null || ratingKey == null) {
      // Use the queue's own item object: the player only keeps a queue when
      // the item it opens carries that queue's item id.
      final candidate = match ?? queue.selectedItem ?? queueItems.first;
      if (total > 1) {
        item = candidate;
        followQueue = queue;
      } else if (ratingKey == null) {
        item = candidate;
      }
    }
  }
  if (item == null && ratingKey != null) {
    item = await client.fetchItem(ratingKey);
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

  // Publish the queue only now: the player that was just closed clears the
  // queue state while tearing down, which would wipe it if done earlier.
  if (followQueue != null) {
    final playbackState = Provider.of<PlaybackStateProvider>(context, listen: false);
    playbackState.setPlayQueueWindowFetcher((id, {center, window = 50}) => client.getPlayQueue(id, center: center, window: window));
    // The context key is a non-null marker that matches no show or playlist
    // id, so Plezy never replaces this queue with a season-order one.
    await playbackState.setPlaybackFromPlayQueue(followQueue, 'plexCompanion:${followQueue.playQueueID}');
    appLogger.i(
      'PlexCompanion: following play queue ${followQueue.playQueueID} '
      '(${followQueue.playQueueShuffled ? 'shuffled, ' : ''}${followQueue.playQueueTotalCount ?? followQueue.size ?? followQueue.items?.length ?? '?'} items)',
    );
    if (!context.mounted) {
      throw const PlexCompanionException(503, 'Plezy has no active profile session');
    }
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
