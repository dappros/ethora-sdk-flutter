import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rooms_support.dart';

const _a = 'app_a@conference.xmpp.test';
const _b = 'app_b@conference.xmpp.test';

ChatMessage _m(String room, int n, String text, {bool media = false}) =>
    ChatMessage(
      id: '${archiveId(n)}',
      roomJid: room,
      text: text,
      user: const ChatUser(xmppUsername: 'app_bob', firstName: 'Bob'),
      createdAtMs: DateTime.now().millisecondsSinceEpoch - 60000 + n,
      isMedia: media,
      mimeType: media ? 'image/png' : null,
    );

RoomsHarness _seeded({
  ApiHandler? handler,
  ChatComponentConfig? config,
  List<ChatRoom>? rooms,
}) {
  final h = RoomsHarness(handler: handler, config: config);
  h.controller.state.value = ChatComponentState(
    isInitialized: true,
    user: kMe,
    rooms: rooms ??
        const [
          ChatRoom(
            jid: _a,
            title: 'Alpha',
            unreadCount: 12,
            unreadCapped: true,
            members: [
              ChatRoomMember(xmppUsername: 'app_me'),
              ChatRoomMember(xmppUsername: 'app_bob', firstName: 'Bob'),
            ],
            usersCnt: 2,
          ),
          ChatRoom(jid: _b, title: 'Beta', muted: true, unreadCount: 3),
        ],
    messagesByRoom: {
      _a: [_m(_a, 1, 'hello from alpha')],
      _b: [_m(_b, 2, 'beta text', media: true)],
    },
    selectedRoomJid: _a,
  );
  return h;
}

Widget _host(RoomsHarness h,
    {String? selected,
    ValueChanged<String>? onSelect,
    ChatComponentConfig? config}) {
  return MaterialApp(
    home: Scaffold(
      body: RoomListView(
        controller: h.controller,
        config: config ?? h.controller.config,
        selectedRoomJid: selected,
        onSelectRoom: onSelect ?? (_) {},
      ),
    ),
  );
}

void main() {
  testWidgets('shows title, preview, unread badge with plus and muted icon',
      (tester) async {
    final h = _seeded();
    await tester.pumpWidget(_host(h));
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('hello from alpha'), findsOneWidget);
    // a media message reads as what it is
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('12+'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey(_b)),
        matching: find.byIcon(Icons.notifications_off_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey(_a)),
        matching: find.byIcon(Icons.notifications_off_outlined),
      ),
      findsOneWidget, // only the swipe action, the row itself is not muted
    );
    h.dispose();
  });

  testWidgets('typing and sending replace the preview', (tester) async {
    final h = _seeded();
    final state = h.controller.state.value;
    h.controller.state.value = state.copyWith(rooms: [
      state.rooms[0].copyWith(composingList: ['Bob', 'Ann']),
      state.rooms[1].copyWith(pendingMessages: 2),
    ]);
    await tester.pumpWidget(_host(h));
    expect(find.text('Bob, Ann typing...'), findsOneWidget);
    expect(find.text('2 sending'), findsOneWidget);
    expect(find.text('hello from alpha'), findsNothing);
    h.dispose();
  });

  testWidgets('the search field filters rooms by name', (tester) async {
    final h = _seeded();
    await tester.pumpWidget(_host(h));
    await tester.enterText(find.byType(TextField), 'bet');
    await tester.pump();
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text('No rooms available'), findsOneWidget);
    h.dispose();
  });

  testWidgets('tapping a row selects the room', (tester) async {
    final h = _seeded();
    final picked = <String>[];
    await tester.pumpWidget(_host(h, onSelect: picked.add));
    await tester.tap(find.text('Beta'));
    await tester.pump();
    expect(picked, [_b]);
    h.dispose();
  });

  testWidgets('swipe reveals mute, report and leave; mute calls the API',
      (tester) async {
    final h = _seeded(
        handler: (r) => r.path.contains('/mute')
            ? jsonResponse({
                'result': {'muted': true}
              })
            : null);
    await tester.pumpWidget(_host(h));
    await tester.drag(find.text('Alpha'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('room-action-mute-app_a')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('room-action-report-app_a')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('room-action-leave-app_a')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('room-action-mute-app_a')));
    await tester.pumpAndSettle();
    expect(h.where('PUT', '/v1/chats/my/app_a/mute'), hasLength(1));
    expect(
      h.controller.state.value.rooms.firstWhere((r) => r.jid == _a).muted,
      true,
    );
    h.dispose();
  });

  testWidgets('only one row is open at a time', (tester) async {
    final h = _seeded();
    await tester.pumpWidget(_host(h));
    await tester.drag(find.text('Alpha'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    final alphaOffset = tester.getTopLeft(find.text('Alpha')).dx;
    await tester.drag(find.text('Beta'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    // Alpha slid back
    expect(tester.getTopLeft(find.text('Alpha')).dx, greaterThan(alphaOffset));
    h.dispose();
  });

  testWidgets('leave asks first, then calls the API and drops the row',
      (tester) async {
    final h = _seeded();
    await tester.pumpWidget(_host(h));
    await tester.drag(find.text('Alpha'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-action-leave-app_a')));
    await tester.pumpAndSettle();
    expect(find.text('Leave Chat'), findsOneWidget);
    expect(h.where('DELETE', 'users-access'), isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Leave'));
    await tester.pumpAndSettle();
    expect(h.where('DELETE', '/v1/chats/users-access').single.json, {
      'chatName': 'app_a',
      'members': ['app_me'],
    });
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
    h.dispose();
  });

  testWidgets('cancelling the leave confirm keeps the chat', (tester) async {
    final h = _seeded();
    await tester.pumpWidget(_host(h));
    await tester.drag(find.text('Alpha'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-action-leave-app_a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.where('DELETE', 'users-access'), isEmpty);
    expect(find.text('Alpha'), findsOneWidget);
    h.dispose();
  });

  testWidgets('report: choose a category and submit', (tester) async {
    final h = _seeded();
    await tester.pumpWidget(_host(h));
    await tester.drag(find.text('Alpha'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('room-action-report-app_a')));
    await tester.pumpAndSettle();
    expect(find.text('Report Chat'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('Spam'));
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(h.where('POST', '/v1/chats/reports/app_a').single.json,
        {'category': 'spam', 'text': 'Spam'});
    h.dispose();
  });

  testWidgets('"Other" needs details before it can be sent', (tester) async {
    expect(canSubmitReport('Other', ''), false);
    expect(canSubmitReport('Other', '  x '), true);
    expect(canSubmitReport(null, 'x'), false);
    expect(canSubmitReport('Spam', ''), true);
  });

  testWidgets('disableRoomSwipeActions removes swipe and long press',
      (tester) async {
    final config = const ChatComponentConfig(
      appId: 'app',
      baseUrl: 'https://api.test',
      xmppSettings: kSupportSettings,
      disableRoomSwipeActions: true,
    );
    final h = _seeded(config: config);
    await tester.pumpWidget(_host(h, config: config));
    await tester.drag(find.text('Alpha'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('room-action-mute-app_a')), findsNothing);
    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Report'), findsNothing);
    h.dispose();
  });

  testWidgets('long press opens the same actions as a sheet', (tester) async {
    final h = _seeded();
    await tester.pumpWidget(_host(h));
    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();
    Finder inSheet(String text) => find.descendant(
        of: find.byType(BottomSheet), matching: find.text(text));
    expect(inSheet('Report'), findsOneWidget);
    expect(inSheet('Leave'), findsOneWidget);
    expect(inSheet('Mute notifications'), findsOneWidget);
    h.dispose();
  });

  testWidgets('the directory and new chat buttons follow the config',
      (tester) async {
    final h = _seeded();
    await tester.pumpWidget(_host(h));
    expect(find.byTooltip('Discover chats'), findsOneWidget);
    expect(find.byTooltip('New chat'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final off = const ChatComponentConfig(
      appId: 'app',
      baseUrl: 'https://api.test',
      xmppSettings: kSupportSettings,
      disablePublicChatsDirectory: true,
      disableNewChatButton: true,
    );
    final h2 = _seeded(config: off);
    await tester.pumpWidget(_host(h2, config: off));
    expect(find.byTooltip('Discover chats'), findsNothing);
    expect(find.byTooltip('New chat'), findsNothing);
    h.dispose();
    h2.dispose();
  });

  testWidgets('message hits show under the rooms when search is on',
      (tester) async {
    final config = const ChatComponentConfig(
      appId: 'app',
      baseUrl: 'https://api.test',
      xmppSettings: kSupportSettings,
      enableMessageSearch: true,
    );
    final h = _seeded(
      config: config,
      handler: (r) => r.path == '/v2/apps/app/messages/search'
          ? jsonResponse({
              'items': [
                {
                  '_id': 'h1',
                  'chatId': 'app_a',
                  'room': _a,
                  'from': 'app_bob@xmpp.test',
                  'fromUserId': 'u9',
                  'body': 'say hello world',
                  'stanzaId': '${archiveId(1)}',
                  'messageId': 'x',
                  'createdAt': '2026-07-14T10:00:00Z',
                },
              ],
              'total': 1,
              'offset': 0,
              'limit': 20,
            })
          : null,
    );
    await tester.pumpWidget(_host(h, config: config));
    await tester.enterText(find.byType(TextField), 'h');
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.where('GET', '/messages/search'), isEmpty); // one character

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.where('GET', '/messages/search'), isEmpty); // still debouncing
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    final call = h.where('GET', '/messages/search').single;
    expect(call.url.queryParameters['q'], 'hello');
    expect(call.url.queryParameters.containsKey('chatId'), false);
    expect(find.textContaining('say '), findsOneWidget);
    expect(find.text('1 found'), findsOneWidget);
    h.dispose();
  });

  testWidgets('no message hits section when search is not enabled',
      (tester) async {
    final h = _seeded();
    await tester.pumpWidget(_host(h));
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump(const Duration(milliseconds: 500));
    expect(h.where('GET', '/messages/search'), isEmpty);
    h.dispose();
  });
}
