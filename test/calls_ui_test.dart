import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:ethora_sdk_flutter/src/calls/call_mode.dart' as mode;
import 'package:ethora_sdk_flutter/src/i18n/chat_i18n.dart';
import 'package:ethora_sdk_flutter/src/ui/calls/call_screens.dart';
import 'package:ethora_sdk_flutter/src/ui/calls/call_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

ChatComponentController controllerFor(VideoCallsConfig? videoCalls) {
  return ChatComponentController(
    config: ChatComponentConfig(videoCalls: videoCalls),
    store: InMemoryStore(),
  );
}

Widget host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

const ChatRoom privateRoom = ChatRoom(jid: 'a-b@conference.h', type: 'private');
const ChatRoom groupRoom = ChatRoom(jid: 'g@conference.h', type: 'group');
const ChatRoom publicRoom = ChatRoom(jid: 'p@conference.h', type: 'public');

void main() {
  group('CallHeaderButtons', () {
    testWidgets(
        'renders nothing when calls are off or the room is not '
        'allowed', (tester) async {
      final off = controllerFor(null);
      await tester.pumpWidget(
        host(CallHeaderButtons(
          controller: off,
          config: off.config,
          room: privateRoom,
        )),
      );
      expect(find.byType(IconButton), findsNothing);

      final on = controllerFor(const VideoCallsConfig(
        enabled: true,
        livekitUrl: 'wss://lk.example.com',
      ));
      await tester.pumpWidget(
        host(CallHeaderButtons(
          controller: on,
          config: on.config,
          room: publicRoom,
        )),
      );
      expect(find.byType(IconButton), findsNothing,
          reason: 'public never calls');

      final privateOnly = controllerFor(const VideoCallsConfig(
        enabled: true,
        livekitUrl: 'wss://lk.example.com',
        allowedRoomTypes: <CallRoomType>[CallRoomType.private],
      ));
      await tester.pumpWidget(
        host(CallHeaderButtons(
          controller: privateOnly,
          config: privateOnly.config,
          room: groupRoom,
        )),
      );
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('video button always, audio only with enableAudioCalls',
        (tester) async {
      final video = controllerFor(const VideoCallsConfig(
        enabled: true,
        livekitUrl: 'wss://lk.example.com',
      ));
      await tester.pumpWidget(
        host(CallHeaderButtons(
          controller: video,
          config: video.config,
          room: privateRoom,
        )),
      );
      expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
      expect(find.byIcon(Icons.call_outlined), findsNothing);

      final both = controllerFor(const VideoCallsConfig(
        enabled: true,
        livekitUrl: 'wss://lk.example.com',
        enableAudioCalls: true,
      ));
      await tester.pumpWidget(
        host(CallHeaderButtons(
          controller: both,
          config: both.config,
          room: groupRoom,
        )),
      );
      expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
      expect(find.byIcon(Icons.call_outlined), findsOneWidget);
    });

    testWidgets('without a livekit url the buttons are disabled with a reason',
        (tester) async {
      final c = controllerFor(const VideoCallsConfig(enabled: true));
      await tester.pumpWidget(
        host(CallHeaderButtons(
          controller: c,
          config: c.config,
          room: privateRoom,
        )),
      );
      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(button.onPressed, isNull);
      expect(button.tooltip, contains('not configured'));
    });
  });

  group('CallOverlayHost', () {
    testWidgets('with calls off it is the child, nothing else', (tester) async {
      final c = controllerFor(null);
      await tester.pumpWidget(
        host(CallOverlayHost(
          controller: c,
          config: c.config,
          child: const Text('chat'),
        )),
      );
      expect(find.text('chat'), findsOneWidget);
      expect(find.byType(CallRingScreen), findsNothing);
    });

    testWidgets('idle shows only the chat; the child stays tappable',
        (tester) async {
      final c = controllerFor(const VideoCallsConfig(enabled: true));
      var taps = 0;
      await tester.pumpWidget(
        host(CallOverlayHost(
          controller: c,
          config: c.config,
          child: TextButton(onPressed: () => taps++, child: const Text('chat')),
        )),
      );
      await tester.tap(find.text('chat'));
      expect(taps, 1);
      expect(find.byType(CallRingScreen), findsNothing);
    });
  });

  group('CallRingScreen', () {
    CallSessionState ringing({String? name, bool group = false}) =>
        CallSessionState.incoming(
          roomJid: 'r@c',
          roomName: name,
          token: '',
          callId: 'c1',
          kind: mode.CallKind.video,
          isGroup: group,
          callerName: group ? 'Ann' : null,
          nowMs: 1,
        );

    testWidgets('incoming: shows the name and routes accept / decline',
        (tester) async {
      var accepted = 0;
      var declined = 0;
      await tester.pumpWidget(
        host(CallRingScreen(
          state: ringing(name: 'Ann Lee'),
          onAccept: () => accepted++,
          onDecline: () => declined++,
        )),
      );
      expect(find.text('Ann Lee'), findsOneWidget);
      expect(find.text('Incoming video call'), findsOneWidget);
      await tester.tap(find.byTooltip('Accept'));
      await tester.tap(find.byTooltip('Decline'));
      expect((accepted, declined), (1, 1));
    });

    testWidgets('an unknown caller gets a neutral label, never an id',
        (tester) async {
      await tester.pumpWidget(host(CallRingScreen(state: ringing())));
      expect(find.text('Incoming call'), findsOneWidget);
    });

    testWidgets('a group ring names the caller and the room', (tester) async {
      await tester.pumpWidget(
        host(CallRingScreen(state: ringing(name: 'Team Chat', group: true))),
      );
      expect(find.text('Incoming group video call'), findsOneWidget);
      expect(find.text('Ann is calling in Team Chat'), findsOneWidget);
    });

    testWidgets('error: message and dismiss', (tester) async {
      var dismissed = 0;
      final state = CallSessionState.startOutgoing(
        roomJid: 'r@c',
        roomName: 'Ann',
        nowMs: 1,
      ).withError('No answer - call timed out', 2);
      await tester.pumpWidget(
        host(CallRingScreen(state: state, onDismiss: () => dismissed++)),
      );
      expect(find.text('Call failed'), findsOneWidget);
      expect(find.text('No answer - call timed out'), findsOneWidget);
      await tester.tap(find.text('Dismiss'));
      expect(dismissed, 1);
    });

    testWidgets('outgoing: calling state with a cancel button', (tester) async {
      var cancelled = 0;
      final state = CallSessionState.startOutgoing(
        roomJid: 'r@c',
        roomName: 'Ann',
        nowMs: 1,
      );
      await tester.pumpWidget(
        host(CallRingScreen(state: state, onCancel: () => cancelled++)),
      );
      expect(find.text('Calling...'), findsOneWidget);
      await tester.tap(find.byTooltip('Cancel'));
      expect(cancelled, 1);
    });
  });

  group('call log label', () {
    ChatMessage log(Map<String, String> data) => ChatMessage(
          id: '1',
          roomJid: 'r@c',
          text: 'call-state',
          user: const ChatUser(id: 'sys'),
          createdAtMs: 1,
          system: true,
          data: <String, String>{'type': 'call-state', ...data},
        );
    final strings = ChatStrings.resolve('en', null);

    test('outgoing, incoming, no answer and missed', () {
      CallLogInfo info(Map<String, String> data) =>
          CallLogInfo.fromMessage(log(data), selfXmppUsername: 'me@h')!;
      expect(
        info(<String, String>{
          'callerXmppUsername': 'me',
          'durationMs': '12000'
        }).label(strings),
        'Outgoing call · 12 sec',
      );
      expect(
        info(<String, String>{
          'callerXmppUsername': 'you',
          'durationMs': '60000'
        }).label(strings),
        'Incoming call · 1 min',
      );
      expect(
        info(<String, String>{
          'callerXmppUsername': 'you',
          'durationMs': '125000'
        }).label(strings),
        'Incoming call · 2 min 5 sec',
      );
      expect(
        info(<String, String>{'callerXmppUsername': 'me', 'durationMs': '0'})
            .label(strings),
        'No answer',
      );
      expect(
        info(<String, String>{'callerXmppUsername': 'you', 'durationMs': '0'})
            .label(strings),
        'Missed call',
      );
      expect(
        info(<String, String>{'durationMs': '0'}).label(strings),
        'Missed call',
        reason: 'no caller info: never claim we dialled',
      );
    });

    test('only call-state data is a call log', () {
      final plain = ChatMessage(
        id: '1',
        roomJid: 'r@c',
        text: 'hi',
        user: const ChatUser(id: 'u'),
        createdAtMs: 1,
      );
      expect(isCallLogMessage(plain), isFalse);
      expect(
        CallLogInfo.fromMessage(plain, selfXmppUsername: 'me'),
        isNull,
      );
      expect(isCallLogMessage(log(const <String, String>{})), isTrue);
    });
  });

  test('formatCallClock', () {
    expect(formatCallClock(const Duration(seconds: 5)), '00:05');
    expect(formatCallClock(const Duration(seconds: 125)), '02:05');
    expect(formatCallClock(const Duration(seconds: 3725)), '1:02:05');
    expect(formatCallClock(const Duration(seconds: -3)), '00:00');
  });
}
