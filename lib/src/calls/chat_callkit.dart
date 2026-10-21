// Host-facing helpers for incoming-call pushes. They work without a
// [ChatComponentController], so they can run from the host's background push
// handler (an FCM background isolate on Android, the PushKit callback on iOS)
// when the app is not running.

import 'dart:async';

import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'call_push.dart';
import 'flutter_native_call_ui.dart';
import 'native_call_ui.dart';

class ChatCallKit {
  const ChatCallKit._();

  /// Rings the native call UI for a call push. Call it from the host's
  /// background message handler (annotate the handler with
  /// `@pragma('vm:entry-point')`). Returns false when [data] is not a call
  /// push, has no call id, or the call token already expired.
  ///
  /// On iOS a VoIP (PushKit) push MUST be reported to CallKit as soon as it
  /// arrives or the system terminates the app, so call this first thing.
  static Future<bool> showIncomingFromPush(
    Map<String, dynamic> data, {
    String appName = 'Ethora',
  }) async {
    if (!looksLikeCallPush(data)) return false;
    final push = parseCallPush(data);
    final callId = push.callId;
    if (callId == null) return false;
    if (isCallTokenExpired(push.exp)) return false;
    final name = push.callerName.isNotEmpty ? push.callerName : '';
    await FlutterNativeCallUi(appName: appName).showIncoming(
      NativeCallInfo(
        callId: callId,
        callerName: name,
        kind: push.kind,
        isGroup: push.group,
        extra: <String, dynamic>{...data, 'callId': callId},
      ),
    );
    return true;
  }

  /// Dismisses the native UI of [callId] (the caller hung up before you
  /// answered, seen in a later push or on reconnect).
  static Future<void> endCall(String callId) =>
      FlutterCallkitIncoming.endCall(callUuid(callId));

  static Future<void> endAllCalls() => FlutterCallkitIncoming.endAllCalls();

  /// The PushKit VoIP token (iOS), null elsewhere or before it is known.
  /// Register it with `controller.registerPushToken(token, tokenType:
  /// PushTokenType.apnsVoip)`.
  static Future<String?> voipPushToken() async {
    final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
    return token == null || token.isEmpty ? null : token;
  }

  /// Android 13+ notification permission and Android 14+ full-screen intent
  /// permission, both needed for the incoming call to show over the lock
  /// screen. Safe to call on iOS (no-ops there).
  static Future<void> requestPermissions() async {
    await FlutterCallkitIncoming
        .requestNotificationPermission(<String, dynamic>{
      'title': 'Notification permission',
      'rationaleMessagePermission':
          'Notifications are needed to show incoming calls.',
      'postNotificationMessageRequired':
          'Allow notifications in Settings to receive incoming calls.',
    });
    if (!await FlutterCallkitIncoming.canUseFullScreenIntent()) {
      await FlutterCallkitIncoming.requestFullIntentPermission();
    }
  }
}
