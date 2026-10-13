import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/plex_companion/plex_companion_server.dart';
import 'package:plezy/services/plex_companion/plex_companion_types.dart';

class _FakePlayer implements PlexCompanionPlayerControls {
  final calls = <String>[];
  PlexCompanionState state = PlexCompanionState.playing;

  @override
  PlexCompanionTimeline get timeline => PlexCompanionTimeline(
    state: state,
    ratingKey: '42',
    position: const Duration(seconds: 5),
    duration: const Duration(minutes: 1),
  );

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async {
    calls.add('pause');
    state = PlexCompanionState.paused;
  }

  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seekTo(Duration position) async => calls.add('seekTo:${position.inMilliseconds}');
  @override
  Future<void> skipNext() async => calls.add('skipNext');
  @override
  Future<void> skipPrevious() async => calls.add('skipPrevious');
  @override
  Future<void> stepForward() async => calls.add('stepForward');
  @override
  Future<void> stepBack() async => calls.add('stepBack');
  @override
  Future<void> setVolume(int percent) async => calls.add('volume:$percent');
}

class _FakeHost implements PlexCompanionHost {
  _FakeHost(this.activePlayer);

  @override
  PlexCompanionPlayerControls? activePlayer;
  PlexCompanionPlayMediaRequest? played;
  final navigated = <PlexCompanionNavigation>[];

  @override
  Future<void> playMedia(PlexCompanionPlayMediaRequest request) async {
    if (request.serverMachineIdentifier == 'unknown') throw const PlexCompanionException(404, 'no server');
    played = request;
  }

  @override
  bool navigate(PlexCompanionNavigation action) {
    navigated.add(action);
    return true;
  }
}

Future<(int, String, HttpHeaders)> _get(int port, String path) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return (res.statusCode, body, res.headers);
  } finally {
    client.close(force: true);
  }
}

void main() {
  const info = PlexCompanionDeviceInfo(identifier: 'abc-123', name: 'Test PC');
  late _FakePlayer player;
  late _FakeHost host;
  late PlexCompanionServer server;
  late int port;

  setUp(() async {
    player = _FakePlayer();
    host = _FakeHost(player);
    server = PlexCompanionServer(host: host, info: info);
    port = await server.start(preferredPort: 0);
  });

  tearDown(() => server.stop());

  test('/resources identifies the player', () async {
    final (status, body, headers) = await _get(port, '/resources');
    expect(status, 200);
    expect(body, contains('machineIdentifier="abc-123"'));
    expect(headers.value('x-plex-client-identifier'), 'abc-123');
  });

  test('timeline poll reflects the player and echoes commandID', () async {
    final (_, body, _) = await _get(port, '/player/timeline/poll?wait=0&commandID=9');
    expect(body, contains('commandID="9"'));
    expect(body, contains('state="playing"'));
    expect(body, contains('ratingKey="42"'));
  });

  test('idle poll reports navigation', () async {
    host.activePlayer = null;
    final (_, body, _) = await _get(port, '/player/timeline/poll');
    expect(body, contains('location="navigation"'));
  });

  test('transport commands reach the player', () async {
    for (final p in [
      '/player/playback/pause?type=video&commandID=1',
      '/player/playback/play',
      '/player/playback/seekTo?offset=30000',
      // Home Assistant sends the position as a float.
      '/player/playback/seekTo?offset=754000.0',
      '/player/playback/seekTo?offset=754320.6',
      '/player/playback/setParameters?volume=55',
      '/player/playback/setParameters?volume=55.0',
      '/player/playback/setParameters?volume=900',
      '/player/playback/skipNext',
      '/player/playback/skipPrevious',
      '/player/playback/stepForward',
      '/player/playback/stepBack',
      '/player/playback/stop',
    ]) {
      final (status, body, _) = await _get(port, p);
      expect(status, 200, reason: p);
      expect(body, contains('code="200"'));
    }
    expect(player.calls, [
      'pause',
      'play',
      'seekTo:30000',
      'seekTo:754000',
      'seekTo:754321',
      'volume:55',
      'volume:55',
      'volume:100',
      'skipNext',
      'skipPrevious',
      'stepForward',
      'stepBack',
      'stop',
    ]);
  });

  test('commands are accepted while idle', () async {
    host.activePlayer = null;
    final (status, _, _) = await _get(port, '/player/playback/pause');
    expect(status, 200);
  });

  test('seekTo without an offset is a 400', () async {
    final (status, _, _) = await _get(port, '/player/playback/seekTo');
    expect(status, 400);
  });

  test('playMedia is parsed and handed to the host', () async {
    final (status, _, _) = await _get(
      port,
      '/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F5&machineIdentifier=srv&offset=1000'
      '&containerKey=%2FplayQueues%2F3%3Fwindow%3D100%26own%3D1',
    );
    expect(status, 200);
    expect(host.played?.key, '/library/metadata/5');
    expect(host.played?.containerKey, '/playQueues/3?window=100&own=1');
    expect(host.played?.offset, const Duration(seconds: 1));
  });

  test('host failures become the HTTP status', () async {
    final (status, _, _) = await _get(port, '/player/playback/playMedia?key=%2Flibrary%2Fmetadata%2F5&machineIdentifier=unknown');
    expect(status, 404);
  });

  test('navigation maps to host actions', () async {
    await _get(port, '/player/navigation/moveUp');
    await _get(port, '/player/navigation/select');
    await _get(port, '/player/navigation/toggleOSD');
    expect(host.navigated, [PlexCompanionNavigation.up, PlexCompanionNavigation.select]);
  });

  test('unknown paths are 404', () async {
    final (status, _, _) = await _get(port, '/nope');
    expect(status, 404);
  });
}
