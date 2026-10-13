import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import '../../models/companion_remote/remote_command.dart';
import '../../utils/app_logger.dart';
import '../../utils/device_identity.dart';
import '../../utils/platform_detector.dart';
import '../companion_remote/companion_remote_receiver.dart';
import '../settings_service.dart';
import '../storage_service.dart';
import 'plex_companion_gdm.dart';
import 'plex_companion_launcher.dart';
import 'plex_companion_server.dart';
import 'plex_companion_types.dart';

/// Where the video player screen publishes itself so the Companion server can
/// read its timeline and drive it. At most one player is on screen.
class PlexCompanionBridge {
  PlexCompanionBridge._();

  static final PlexCompanionBridge instance = PlexCompanionBridge._();

  Object? _owner;
  PlexCompanionPlayerControls? _controls;

  PlexCompanionPlayerControls? get activePlayer => _controls;

  void attach(Object owner, PlexCompanionPlayerControls controls) {
    _owner = owner;
    _controls = controls;
  }

  /// Only the current owner can detach, so a replaced screen disposing late
  /// cannot unregister its successor.
  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _controls = null;
  }
}

class _AppHost implements PlexCompanionHost {
  @override
  PlexCompanionPlayerControls? get activePlayer => PlexCompanionBridge.instance.activePlayer;

  @override
  Future<void> playMedia(PlexCompanionPlayMediaRequest request) => launchPlexCompanionPlayback(request);

  @override
  bool navigate(PlexCompanionNavigation action) {
    final type = switch (action) {
      PlexCompanionNavigation.up => RemoteCommandType.dpadUp,
      PlexCompanionNavigation.down => RemoteCommandType.dpadDown,
      PlexCompanionNavigation.left => RemoteCommandType.dpadLeft,
      PlexCompanionNavigation.right => RemoteCommandType.dpadRight,
      PlexCompanionNavigation.select => RemoteCommandType.select,
      PlexCompanionNavigation.back => RemoteCommandType.back,
      PlexCompanionNavigation.home => RemoteCommandType.home,
      PlexCompanionNavigation.contextMenu => RemoteCommandType.contextMenu,
    };
    CompanionRemoteReceiver.instance.handleCommand(RemoteCommand(type: type), null);
    return true;
  }
}

/// Owns the lifetime of the Plex Companion server and GDM discovery.
class PlexCompanionController {
  PlexCompanionController._();

  static final PlexCompanionController instance = PlexCompanionController._();

  PlexCompanionServer? _server;
  PlexCompanionGdm? _gdm;
  Future<void>? _starting;

  bool get isRunning => _server?.isRunning ?? false;

  /// Starts or stops to match the user's setting. Safe to call repeatedly.
  Future<void> sync() async {
    final settings = await SettingsService.getInstance();
    if (settings.read(SettingsService.enablePlexCompanion)) {
      await start();
    } else {
      await stop();
    }
  }

  Future<void> start() {
    if (isRunning) return Future<void>.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    try {
      final storage = await StorageService.getInstance();
      final identifier = await storage.getOrCreateClientIdentifier();
      final device = await DeviceIdentityService.resolve();
      final package = await PackageInfo.fromPlatform();

      final info = PlexCompanionDeviceInfo(
        identifier: identifier,
        name: (device.deviceName?.trim().isNotEmpty ?? false) ? device.deviceName!.trim() : 'Plezy',
        platform: device.platform,
        version: package.version,
        deviceClass: PlatformDetector.isTV()
            ? 'stb'
            : (Platform.isAndroid || Platform.isIOS)
            ? 'phone'
            : 'pc',
      );

      void log(String message) => appLogger.i(message);
      final server = PlexCompanionServer(host: _AppHost(), info: info, log: log);
      final port = await server.start();
      final gdm = PlexCompanionGdm(info: info, httpPort: port, log: log);
      await gdm.start();

      _server = server;
      _gdm = gdm;
      appLogger.i('PlexCompanion: advertising "${info.name}" (${info.identifier}) on port $port');
    } catch (e, st) {
      appLogger.e('PlexCompanion: failed to start', error: e, stackTrace: st);
      await stop();
    }
  }

  Future<void> stop() async {
    final server = _server;
    final gdm = _gdm;
    _server = null;
    _gdm = null;
    await gdm?.stop();
    await server?.stop();
  }
}
