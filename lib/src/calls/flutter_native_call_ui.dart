// The real [NativeCallUi]: flutter_callkit_incoming. On iOS it reports the
// call to CallKit; on Android it shows the full-screen incoming-call
// notification (with the system ringtone) and runs the ongoing-call
// foreground service (phoneCall | microphone | camera) behind an active call.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'call_mode.dart';
import 'native_call_ui.dart';

const String _kNativeAppName = 'Ethora';

/// Ring time on the native UI before it reports a missed call.
const int kNativeRingTimeoutMs = 45000;

class FlutterNativeCallUi implements NativeCallUi {
  FlutterNativeCallUi({this.appName = _kNativeAppName});

  final String appName;

  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  @override
  Stream<NativeCallEvent> get events => FlutterCallkitIncoming.onEvent
      .map(_toEvent)
      .where((event) => event != null)
      .cast<NativeCallEvent>();

  NativeCallEvent? _toEvent(CallEvent? event) {
    CallKitParams? params;
    NativeCallEventType? type;
    switch (event) {
      case CallEventActionCallAccept():
        params = event.callKitParams;
        type = NativeCallEventType.accept;
      case CallEventActionCallDecline():
        params = event.callKitParams;
        type = NativeCallEventType.decline;
      case CallEventActionCallEnded():
        params = event.callKitParams;
        type = NativeCallEventType.ended;
      case CallEventActionCallTimeout():
        return NativeCallEvent(
            type: NativeCallEventType.timeout, uuid: event.id);
      default:
        return null;
    }
    final extra = <String, dynamic>{...?params.extra};
    return NativeCallEvent(
      type: type,
      uuid: params.id,
      callId: '${extra['callId'] ?? ''}'.isEmpty ? null : '${extra['callId']}',
      extra: extra,
    );
  }

  CallKitParams _params(NativeCallInfo info, {bool ongoing = false}) {
    final video = info.kind == CallKind.video;
    final name = info.callerName.isNotEmpty
        ? info.callerName
        : (info.roomName.isNotEmpty ? info.roomName : appName);
    final subtitle = info.isGroup
        ? (video ? 'Group video call' : 'Group audio call')
        : (video ? 'Video call' : 'Audio call');
    return CallKitParams(
      id: info.uuid,
      nameCaller: name,
      appName: appName,
      handle: info.roomName.isNotEmpty ? info.roomName : subtitle,
      type: video ? 1 : 0,
      duration: kNativeRingTimeoutMs,
      // The push data round-trips so an accept after a cold start can rebuild
      // the call.
      extra: <String, dynamic>{...info.extra, 'callId': info.callId},
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: false,
        subtitle: 'Missed call',
      ),
      callingNotification: NotificationParams(
        showNotification: true,
        isShowCallback: true,
        subtitle: ongoing ? 'Ongoing $subtitle' : subtitle,
        callbackText: 'Hang up',
      ),
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        isShowCallID: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0B1730',
        actionColor: '#10B981',
        textColor: '#ffffff',
        incomingCallNotificationChannelName: 'Incoming call',
        missedCallNotificationChannelName: 'Missed call',
        textAccept: 'Accept',
        textDecline: 'Decline',
      ),
      ios: IOSParams(
        handleType: 'generic',
        supportsVideo: video,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        supportsDTMF: false,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        includesCallsInRecents: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );
  }

  @override
  Future<void> showIncoming(NativeCallInfo info) =>
      FlutterCallkitIncoming.showCallkitIncoming(_params(info));

  @override
  Future<void> startOngoing(NativeCallInfo info) async {
    // iOS keeps the app alive through the audio background mode; reporting
    // every call to CallKit would also fight the WebRTC audio session.
    if (!_android) return;
    await FlutterCallkitIncoming.startCall(_params(info, ongoing: true));
  }

  @override
  Future<void> markConnected(NativeCallInfo info) async {
    if (!_android) return;
    await FlutterCallkitIncoming.setCallConnected(info.uuid);
  }

  @override
  Future<void> end(NativeCallInfo info) =>
      FlutterCallkitIncoming.endCall(info.uuid);

  @override
  Future<List<NativeCallInfo>> activeCalls() async {
    final calls = await FlutterCallkitIncoming.activeCalls();
    return <NativeCallInfo>[
      for (final call in calls)
        if ('${call.extra?['callId'] ?? ''}'.isNotEmpty)
          NativeCallInfo(
            callId: '${call.extra!['callId']}',
            callerName: call.nameCaller ?? '',
            roomName: call.handle ?? '',
            kind: call.type == 1 ? CallKind.video : CallKind.audio,
            extra: <String, dynamic>{...?call.extra},
            accepted: call.isAccepted,
          ),
    ];
  }
}
