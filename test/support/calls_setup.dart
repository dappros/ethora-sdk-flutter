import 'dart:async';
import 'dart:convert';

import 'package:ethora_sdk_flutter/src/calls/call_api.dart';
import 'package:ethora_sdk_flutter/src/calls/call_mode.dart';
import 'package:ethora_sdk_flutter/src/calls/call_state.dart';
import 'package:ethora_sdk_flutter/src/calls/calls_coordinator.dart';
import 'package:ethora_sdk_flutter/src/calls/livekit_session_port.dart';
import 'package:ethora_sdk_flutter/src/calls/p2p/p2p_signal.dart';
import 'package:ethora_sdk_flutter/src/models/chat_component_config.dart';
import 'package:ethora_sdk_flutter/src/models/chat_message.dart';
import 'package:ethora_sdk_flutter/src/models/chat_room.dart';
import 'package:ethora_sdk_flutter/src/models/chat_user.dart';
import 'package:ethora_sdk_flutter/src/models/video_calls_config.dart';
import 'package:ethora_sdk_flutter/src/networking/xmpp_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'calls_fakes.dart';

const String hex24 = '0123456789abcdef01234567';
const String systemFrom = '${hex24}_$hex24@xmpp.example.com';
const String roomName = 'me-you';
const String roomJid = '$roomName@conference.xmpp.example.com';
const String groupName = 'team';
const String groupJid = '$groupName@conference.xmpp.example.com';

class FakeHost implements CallsHost {
  FakeHost({this.videoCalls});

  @override
  VideoCallsConfig? videoCalls;
  @override
  String selfXmppUsername = 'me';
  @override
  String xmppDomain = 'xmpp.example.com';
  @override
  List<ChatRoom> rooms = <ChatRoom>[
    const ChatRoom(
      jid: roomJid,
      title: 'Ann Lee',
      type: 'private',
      usersCnt: 2,
      members: <ChatRoomMember>[
        ChatRoomMember(xmppUsername: 'me', firstName: 'Me'),
        ChatRoomMember(xmppUsername: 'you', firstName: 'Ann', lastName: 'Lee'),
      ],
    ),
    const ChatRoom(
      jid: groupJid,
      title: 'Team Chat',
      type: 'group',
      usersCnt: 5,
    ),
  ];
  @override
  String conferenceDomain = 'conference.xmpp.example.com';
  final List<XmlElement> sent = <XmlElement>[];
  final List<ChatMessage> callLogs = <ChatMessage>[];
  bool online = true;

  @override
  void addCallLog(ChatMessage message) => callLogs.add(message);

  @override
  bool sendStanza(String stanza) {
    if (!online) return false;
    sent.add(XmlDocument.parse(stanza).rootElement);
    return true;
  }

  @override
  void log(String message, [Object? detail]) {}

  List<String> sentDataTypes() => sent
      .map((m) => m.getElement('data')?.getAttribute('type') ?? '')
      .toList();

  List<XmlElement> sentOfType(String type) => sent
      .where((m) => m.getElement('data')?.getAttribute('type') == type)
      .toList();

  /// The `signal` values of the call-p2p messages sent so far.
  List<String> p2pSignals() => sentOfType('call-p2p')
      .map((m) => m.getElement('data')!.getAttribute('signal')!)
      .toList();
}

class FakeApi implements CallApi {
  CallCreateResult? result;
  Object? error;
  Completer<CallCreateResult>? gate;
  final List<String> created = <String>[];
  final List<String> reports = <String>[];
  int iceFetches = 0;

  @override
  Future<CallCreateResult> createCall(String chatName, CallKind kind) async {
    created.add('$chatName:${kind.name}');
    final g = gate;
    if (g != null) return g.future;
    if (error != null) throw error!;
    return result!;
  }

  @override
  void reportRinging(String? callId) => reports.add('ringing:$callId');
  @override
  void reportDeclined(String? callId) => reports.add('decline:$callId');
  @override
  void reportConnected(String? callId) => reports.add('connected:$callId');
  @override
  void reportEnded(String? callId) => reports.add('end:$callId');

  @override
  Future<List<IceServerConfig>?> fetchIceServers() async {
    iceFetches++;
    return null;
  }
}

class FakeLiveKit implements LiveKitSession {
  FakeLiveKit(this.params, this.events);
  final LiveKitSessionParams params;
  final LiveKitSessionEvents events;
  bool connected = false;
  bool disposed = false;

  @override
  LiveKitSnapshot get snapshot => const LiveKitSnapshot();
  @override
  void Function() subscribe(void Function() listener) => () {};
  @override
  Future<void> connect() async => connected = true;
  @override
  Future<void> toggleMic() async {}
  @override
  Future<void> toggleCamera() async {}
  @override
  Future<void> flipCamera() async {}
  @override
  Future<void> toggleScreenShare() async {}
  @override
  Future<void> setSpeaker(bool on) async {}
  @override
  void dismissNotice() {}
  @override
  Future<void> dispose() async => disposed = true;
}

class Setup {
  Setup({
    VideoCallsConfig? config,
    Duration? outgoingTimeout,
    Duration? incomingRingTimeout,
    FakeNativeUi? nativeUi,
    FakeTonePlayer? tonePlayer,
    bool Function()? appResumed,
  }) : host = FakeHost(
          videoCalls: config ??
              const VideoCallsConfig(
                enabled: true,
                livekitUrl: 'wss://lk.example.com',
                enableAudioCalls: true,
              ),
        ) {
    calls = CallsCoordinator(
      host: host,
      api: api,
      p2pDeps: ({required fetchIce, required sendSignal, required log}) {
        final deps = WiredDeps(sendSignal, fetchIce);
        p2pDeps.add(deps);
        return deps;
      },
      livekit: (params, events) {
        final session = FakeLiveKit(params, events);
        sessions.add(session);
        return session;
      },
      scheduler: scheduler.call,
      now: () => nowMs,
      outgoingTimeout: outgoingTimeout ?? const Duration(seconds: 30),
      incomingRingTimeout: incomingRingTimeout ?? const Duration(seconds: 60),
      nativeUi: nativeUi,
      tonePlayer: tonePlayer,
      appResumed: appResumed,
    );
    xmpp = XmppClient(
      settings: const XmppSettings(
        host: 'xmpp.example.com',
        conference: 'conference.xmpp.example.com',
      ),
      user: const ChatUser(id: 'me', xmppUsername: 'me'),
      log: (_) {},
    );
    calls.attach(xmpp);
  }

  int nowMs = 1760000000000;
  final FakeHost host;
  final FakeApi api = FakeApi();
  final ManualScheduler scheduler = ManualScheduler();
  final List<FakeP2pDeps> p2pDeps = <FakeP2pDeps>[];
  final List<FakeLiveKit> sessions = <FakeLiveKit>[];
  late final CallsCoordinator calls;
  late final XmppClient xmpp;

  CallSessionState get state => calls.state;

  /// Feeds a stanza through the interceptor chain like the XMPP client does.
  /// Returns true when the calls module consumed it.
  bool deliver(XmlElement message) {
    for (final interceptor in xmpp.messageInterceptors) {
      if (interceptor(message)) return true;
    }
    return false;
  }

  bool deliverXml(String xml) => deliver(XmlDocument.parse(xml).rootElement);

  String stanzaId([int ageMs = 500]) =>
      '<stanza-id xmlns="urn:xmpp:sid:0" by="x" id="${nowMs - ageMs}123"/>';

  bool p2pToken({
    String callId = 'p1',
    String room = roomName,
    String kind = 'video',
    String from = systemFrom,
    int ageMs = 500,
  }) {
    final ice = jsonEncode(<Object>[
      <String, String>{'urls': 'turn:t.example.com', 'username': 'u'},
    ]);
    return deliverXml(
      '<message from="$from" type="chat">'
      "<data type=\"call-token\" mode=\"p2p\" room=\"$room\" callId=\"$callId\" "
      "kind=\"$kind\" callerName=\"Ann Lee\" caller=\"you\" ice='$ice'/>"
      '${stanzaId(ageMs)}</message>',
    );
  }

  bool lkToken({
    String callId = 'l1',
    String room = roomName,
    String extra = '',
    int ageMs = 500,
  }) {
    return deliverXml(
      '<message from="$systemFrom" type="chat">'
      '<data type="call-token" token="jwt" room="$room" callId="$callId" '
      'livekitUrl="wss://server.example.com" $extra/>'
      '${stanzaId(ageMs)}</message>',
    );
  }

  bool p2pSignalFromPeer(
    P2PSignalName name,
    P2PSignalPayload payload, {
    String callId = 'p1',
    String from = 'you',
  }) {
    final xml = buildP2PSignalStanza(
      to: 'me@xmpp.example.com',
      callId: callId,
      signal: name,
      payload: payload,
    );
    final root = XmlDocument.parse(xml).rootElement
      ..setAttribute('from', '$from@xmpp.example.com/res');
    return deliver(root);
  }

  Future<void> settle() => pumpEventQueue();
}

/// [FakeP2pDeps] whose signals also go out through the coordinator's
/// callback, exactly like the production deps: as real call-p2p stanzas.
class WiredDeps extends FakeP2pDeps {
  WiredDeps(this._send, this._fetch);
  final void Function(P2PSignalName, P2PSignalPayload) _send;
  final Future<List<IceServerConfig>?> Function() _fetch;

  @override
  void sendSignal(P2PSignalName signal, P2PSignalPayload payload) {
    super.sendSignal(signal, payload);
    _send(signal, payload);
  }

  @override
  Future<List<IceServerConfig>?> fetchIceServers() {
    iceFetches++;
    return _fetch();
  }
}

const CallCreateResult p2pCreated = CallCreateResult(
  callId: 'p1',
  mode: CallMode.p2p,
  kind: CallKind.video,
  group: null,
  livekitUrl: null,
  iceServers: <IceServerConfig>[
    IceServerConfig(urls: <String>['turn:t.example.com'], username: 'u'),
  ],
  ttlSeconds: 3600,
);

const CallCreateResult lkCreated = CallCreateResult(
  callId: 'l1',
  mode: CallMode.livekit,
  kind: CallKind.video,
  group: false,
  livekitUrl: null,
  iceServers: <IceServerConfig>[],
  ttlSeconds: null,
);
