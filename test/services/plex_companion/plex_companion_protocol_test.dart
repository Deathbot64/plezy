import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/plex_companion/plex_companion_protocol.dart';
import 'package:plezy/services/plex_companion/plex_companion_types.dart';

const _info = PlexCompanionDeviceInfo(
  identifier: '2f1c9a3e-1111-4222-8333-abcdefabcdef',
  name: 'Gaming PC: Living "Room"',
  platform: 'Windows',
  version: '1.2.3',
);

void main() {
  group('GDM', () {
    test('every header line has exactly one colon (python-plexapi unpacks line.split(":") into two)', () {
      final reply = buildGdmSearchResponse(_info, 32500);
      final lines = reply.split('\n').where((l) => l.contains(':'));
      expect(lines, isNotEmpty);
      for (final line in lines) {
        expect(':'.allMatches(line).length, 1, reason: line);
      }
    });

    test('reply fits one 1024 byte datagram and carries the identity', () {
      final reply = buildGdmSearchResponse(_info, 32500);
      expect(reply.length, lessThan(1024));
      expect(reply, startsWith('HTTP/1.0 200 OK\n'));
      expect(reply, contains('Resource-Identifier: ${_info.identifier}\n'));
      expect(reply, contains('Port: 32500\n'));
      expect(reply, contains('Protocol-Capabilities: timeline,playback,navigation\n'));
    });

    test('uses plain newlines with no trailing newline (the layout plex-mpv-shim uses)', () {
      for (final message in [
        buildGdmSearchResponse(_info, 1),
        buildGdmHello(_info, 1),
        buildGdmBye(_info, 1),
      ]) {
        expect(message.contains('\r'), isFalse);
        expect(message.endsWith('\n'), isFalse);
      }
    });

    test('carries RawName like plex-mpv-shim', () {
      expect(buildGdmHello(_info, 1), contains('RawName: Gaming PC- Living "Room"\n'));
    });

    test('hello and bye use the registration verbs', () {
      expect(buildGdmHello(_info, 1), startsWith('HELLO * HTTP/1.0\n'));
      expect(buildGdmBye(_info, 1), startsWith('BYE * HTTP/1.0\n'));
    });

    test('recognises searches only', () {
      expect(isGdmSearch('M-SEARCH * HTTP/1.0\r\n\r\n'), isTrue);
      expect(isGdmSearch('M-SEARCH * HTTP/1.1\r\n'), isTrue);
      expect(isGdmSearch('HELLO * HTTP/1.0'), isFalse);
    });

    test('values cannot inject headers', () {
      expect(sanitizeGdmValue('a\r\nX: b'), 'a X- b');
    });
  });

  group('XML', () {
    test('resources advertises playback and the machine identifier', () {
      final xml = buildResourcesXml(_info);
      expect(xml, contains('machineIdentifier="${_info.identifier}"'));
      expect(xml, contains('protocolCapabilities="timeline,playback,navigation"'));
      expect(xml, contains('&quot;Room&quot;'));
    });

    test('idle timeline lists three stopped timelines in navigation', () {
      final xml = buildTimelineXml(PlexCompanionTimeline.stopped, commandId: 4);
      expect(xml, contains('commandID="4"'));
      expect(xml, contains('location="navigation"'));
      expect('state="stopped"'.allMatches(xml).length, 3);
    });

    test('active timeline reports time, duration and keys', () {
      final xml = buildTimelineXml(
        const PlexCompanionTimeline(
          state: PlexCompanionState.playing,
          machineIdentifier: 'srv',
          ratingKey: '42',
          key: '/library/metadata/42',
          position: Duration(seconds: 12),
          duration: Duration(minutes: 10),
          volume: 80,
        ),
      );
      expect(xml, contains('location="fullScreenVideo"'));
      expect(xml, contains('state="playing"'));
      expect(xml, contains('time="12000"'));
      expect(xml, contains('duration="600000"'));
      expect(xml, contains('ratingKey="42"'));
      expect(xml, contains('volume="80"'));
    });
  });

  group('requests', () {
    test('metadata keys', () {
      expect(ratingKeyFromMetadataKey('/library/metadata/123'), '123');
      expect(ratingKeyFromMetadataKey('/library/metadata/123/children'), isNull);
      expect(ratingKeyFromMetadataKey('/playlists/9/items'), isNull);
    });

    test('play queue ids', () {
      expect(playQueueIdFromContainerKey('/playQueues/77?window=100&own=1'), 77);
      expect(playQueueIdFromContainerKey('/library/metadata/1'), isNull);
    });

    test('playMedia parsing', () {
      final r = parsePlayMediaQuery({
        'key': '/library/metadata/5',
        'machineIdentifier': 'abc',
        'offset': '90000',
        'containerKey': '/playQueues/1?window=100&own=1',
        'port': '32400',
      });
      expect(r.key, '/library/metadata/5');
      expect(r.serverMachineIdentifier, 'abc');
      expect(r.offset, const Duration(seconds: 90));
      expect(r.port, 32400);
    });

    test('lenient integers accept floats as Home Assistant sends them', () {
      expect(parseLenientInt('754000.0'), 754000);
      expect(parseLenientInt('754320.6'), 754321);
      expect(parseLenientInt('30000'), 30000);
      expect(parseLenientInt(' 5 '), 5);
      expect(parseLenientInt('abc'), isNull);
      expect(parseLenientInt('NaN'), isNull);
      expect(parseLenientInt(null), isNull);
    });

    test('playMedia without a key is a 400', () {
      expect(
        () => parsePlayMediaQuery({}),
        throwsA(isA<PlexCompanionException>().having((e) => e.statusCode, 'status', 400)),
      );
    });
  });
}
