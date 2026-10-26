// What the platform needs before the screen can be shared in a LiveKit call.
//
// Android requires the user's capture permission and a running
// `mediaProjection` foreground service before capture starts. iOS shares the
// app's own screen without a broadcast extension (sharing other apps needs
// one, see the README), so nothing is needed there.

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

abstract class ScreenShareSupport {
  /// Gets permission and starts what capture needs. False when the user said
  /// no or the platform cannot do it.
  Future<bool> prepare();

  /// Stops what [prepare] started.
  Future<void> release();
}

/// The real thing, over flutter_webrtc and flutter_foreground_task.
class PlatformScreenShareSupport implements ScreenShareSupport {
  PlatformScreenShareSupport({
    this.notificationTitle = 'Sharing your screen',
    this.notificationText = 'Tap to return to the call',
  });

  final String notificationTitle;
  final String notificationText;

  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> prepare() async {
    if (!_android) return true;
    // The system capture prompt must be accepted BEFORE the service starts.
    if (!await rtc.Helper.requestCapturePermission()) return false;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ethora_screen_share',
        channelName: 'Screen sharing',
        channelDescription: 'Shown while you share your screen in a call.',
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: false,
      ),
    );
    if (await FlutterForegroundTask.isRunningService) return true;
    final result = await FlutterForegroundTask.startService(
      serviceTypes: <ForegroundServiceTypes>[
        ForegroundServiceTypes.mediaProjection,
      ],
      notificationTitle: notificationTitle,
      notificationText: notificationText,
    );
    return result is ServiceRequestSuccess;
  }

  @override
  Future<void> release() async {
    if (!_android) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
