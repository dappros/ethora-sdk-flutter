import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rooms_support.dart';

const _a = 'app_a@conference.xmpp.test';

const _config = ChatComponentConfig(
  appId: 'app',
  baseUrl: 'https://api.test',
  xmppSettings: kSupportSettings,
  enableMessageSearch: true,
);

RoomsHarness _seeded({
  ApiHandler? handler,
  List<ChatRoom>? rooms,
  ChatComponentConfig config = _config,
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
            type: 'group',
            role: 'moderator',
            usersCnt: 3,
            description: 'The alpha team',
            members: [
              ChatRoomMember(xmppUsername: 'app_me', firstName: 'Me'),
              ChatRoomMember(
                xmppUsername: 'app_bob',
                id: 'u-bob',
                firstName: 'Bob',
                lastName: 'Stone',
              ),
              ChatRoomMember(
                xmppUsername: 'app_ann',
                id: 'u-ann',
                firstName: 'Ann',
              ),
            ],
          ),
        ],
    messagesByRoom: {
      _a: [
        ChatMessage(
          id: '${archiveId(1)}',
          roomJid: _a,
          text: 'say hello world',
          user: const ChatUser(xmppUsername: 'app_bob', firstName: 'Bob'),
          createdAtMs: 1700000000000,
        ),
      ],
    },
    selectedRoomJid: _a,
  );
  return h;
}

/// A page with one button that runs [open] with the harness' controller.
Widget _opener(RoomsHarness h, Future<void> Function(BuildContext) open) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

/// A tall screen, so a long sheet shows every row without scrolling.
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('public chats directory', () {
    ApiHandler directory() => (r) => r.path == '/v1/chats/public'
        ? jsonResponse({
            'items': [
              {'name': 'app_pub1', 'title': 'Football', 'description': 'Goals'},
              {'name': 'app_pub2', 'title': 'Cooking', 'description': 'Food'},
              {'name': 'app_bad', 'title': 'Reported', 'reported': true},
            ],
            'total': 3,
            'offset': 0,
            'limit': 50,
          })
        : null;

    testWidgets('lists chats, hides reported, filters locally', (tester) async {
      final h = _seeded(handler: directory());
      await tester.pumpWidget(_opener(
        h,
        (c) => showPublicChatsSheet(c, controller: h.controller),
      ));
      await _open(tester);
      expect(find.text('Discover chats'), findsOneWidget);
      expect(find.text('Football'), findsOneWidget);
      expect(find.text('Cooking'), findsOneWidget);
      expect(find.text('Reported'), findsNothing);
      expect(
        h.where('GET', '/v1/chats/public').single.url.queryParameters,
        {'limit': '50', 'offset': '0'},
      );

      await tester.enterText(find.byType(TextField), 'cook');
      await tester.pump();
      expect(find.text('Football'), findsNothing);
      expect(find.text('Cooking'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(find.text('No public chats to show'), findsOneWidget);
      h.dispose();
    });

    testWidgets('Join joins by presence and opens the chat', (tester) async {
      final h = _seeded(handler: directory());
      final opened = <String>[];
      await tester.pumpWidget(_opener(
        h,
        (c) => showPublicChatsSheet(
          c,
          controller: h.controller,
          onOpenRoom: opened.add,
        ),
      ));
      await _open(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Join').first);
      await tester.pumpAndSettle();
      expect(opened, ['app_pub1@conference.xmpp.test']);
      expect(
        h.controller.state.value.rooms.any(
          (r) => r.jid == 'app_pub1@conference.xmpp.test' && r.type == 'public',
        ),
        true,
      );
      expect(h.where('POST', 'chats'), isEmpty); // no REST join
      await tester.pump(const Duration(seconds: 4)); // the delayed refresh
      h.dispose();
    });

    testWidgets('a chat already joined shows Open', (tester) async {
      final h = _seeded(
        handler: directory(),
        rooms: const [
          ChatRoom(jid: 'app_pub1@conference.xmpp.test', title: 'Football'),
        ],
      );
      await tester.pumpWidget(_opener(
        h,
        (c) => showPublicChatsSheet(c, controller: h.controller),
      ));
      await _open(tester);
      expect(find.widgetWithText(OutlinedButton, 'Open'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Join'), findsOneWidget);
      h.dispose();
    });

    testWidgets('an error offers a retry', (tester) async {
      var fail = true;
      final h = _seeded(handler: (r) {
        if (r.path != '/v1/chats/public') return null;
        return fail ? jsonResponse({}, 500) : directory()(r);
      });
      await tester.pumpWidget(_opener(
        h,
        (c) => showPublicChatsSheet(c, controller: h.controller),
      ));
      await _open(tester);
      expect(find.text('Could not load public chats.'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Football'), findsOneWidget);
      h.dispose();
    });
  });

  group('new chat', () {
    testWidgets('private chat: pick a person you share a room with',
        (tester) async {
      final h = _seeded(
          handler: (r) => r.path == '/v1/chats/private'
              ? jsonResponse({
                  'result': {
                    'name': 'app_p',
                    'title': 'Bob Stone',
                    'type': 'private'
                  },
                })
              : null);
      ChatRoom? created;
      await tester.pumpWidget(_opener(h, (c) async {
        created = await showNewChatSheet(
          c,
          controller: h.controller,
          config: h.controller.config,
        );
      }));
      await _open(tester);
      expect(find.text('Bob Stone'), findsOneWidget);
      expect(find.text('Ann'), findsOneWidget);
      expect(find.text('Me'), findsNothing); // never yourself

      await tester.tap(find.text('Bob Stone'));
      await tester.pumpAndSettle();
      expect(h.where('POST', '/v1/chats/private').single.json,
          {'username': 'app_bob'});
      expect(created?.jid, 'app_p@conference.xmpp.test');
      h.dispose();
    });

    testWidgets('private chat by typing a username', (tester) async {
      final h = _seeded(
          handler: (r) => r.path == '/v1/chats/private'
              ? jsonResponse({
                  'result': {'name': 'app_p2', 'type': 'private'},
                })
              : null);
      ChatRoom? created;
      await tester.pumpWidget(_opener(h, (c) async {
        created = await showNewChatSheet(
          c,
          controller: h.controller,
          config: h.controller.config,
        );
      }));
      await _open(tester);
      final start = find.widgetWithText(FilledButton, 'Start chat');
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'app_zed');
      await tester.pump();
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(h.where('POST', '/v1/chats/private').single.json,
          {'username': 'app_zed'});
      expect(created, isNotNull);
      h.dispose();
    });

    testWidgets('a failed create keeps the sheet and says so', (tester) async {
      final h = _seeded(
          handler: (r) => r.path == '/v1/chats/private'
              ? jsonResponse({'message': 'nope'}, 422)
              : null);
      await tester.pumpWidget(_opener(h, (c) async {
        await showNewChatSheet(
          c,
          controller: h.controller,
          config: h.controller.config,
        );
      }));
      await _open(tester);
      await tester.tap(find.text('Ann'));
      await tester.pumpAndSettle();
      expect(find.text('New chat'), findsOneWidget); // sheet still open
      h.dispose();
    });

    testWidgets('group chat: name of 3+ characters, members and type',
        (tester) async {
      _tall(tester);
      final h = _seeded(
          handler: (r) => r.path == '/v1/chats' && r.method == 'POST'
              ? jsonResponse({
                  'result': {
                    'name': 'app_g',
                    'title': 'Team',
                    'type': 'public'
                  },
                })
              : null);
      ChatRoom? created;
      await tester.pumpWidget(_opener(h, (c) async {
        created = await showNewChatSheet(
          c,
          controller: h.controller,
          config: h.controller.config,
        );
      }));
      await _open(tester);
      await tester.tap(find.text('New group'));
      await tester.pumpAndSettle();

      final create = find.widgetWithText(FilledButton, 'Create');
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await tester.enterText(find.byType(TextField).first, 'Te');
      await tester.pump();
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await tester.enterText(find.byType(TextField).first, 'Team');
      await tester.pump();
      expect(tester.widget<FilledButton>(create).onPressed, isNotNull);

      await tester.tap(find.text('Public'));
      await tester.pump();
      await tester.tap(find.text('Ann'));
      await tester.pump();
      await tester.tap(create);
      await tester.pumpAndSettle();
      final body = h.where('POST', '/v1/chats').first.json;
      expect(body['title'], 'Team');
      expect(body['type'], 'public');
      expect(body['description'], 'No description');
      expect(body['members'], ['app_ann']);
      expect(created?.jid, 'app_g@conference.xmpp.test');
      h.dispose();
    });
  });

  group('room info', () {
    testWidgets('shows the profile and the members', (tester) async {
      _tall(tester);
      final h = _seeded();
      await tester.pumpWidget(_opener(
        h,
        (c) => showRoomInfo(
          c,
          controller: h.controller,
          config: h.controller.config,
          roomJid: _a,
        ),
      ));
      await _open(tester);
      expect(find.text('Chat Profile'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('3 members'), findsOneWidget);
      expect(find.text('The alpha team'), findsOneWidget);
      expect(find.text('Group'), findsOneWidget);
      expect(find.text('Bob Stone'), findsOneWidget);
      expect(find.text('Me (You)'), findsOneWidget);
      h.dispose();
    });

    testWidgets('a moderator can add and remove; nobody can remove themselves',
        (tester) async {
      _tall(tester);
      final h = _seeded();
      await tester.pumpWidget(_opener(
        h,
        (c) => showRoomInfo(
          c,
          controller: h.controller,
          config: h.controller.config,
          roomJid: _a,
        ),
      ));
      await _open(tester);
      expect(find.text('Add members'), findsOneWidget);
      // Bob and Ann, not me
      expect(find.byIcon(Icons.person_remove_alt_1_outlined), findsNWidgets(2));
      expect(find.text('Delete chat'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.person_remove_alt_1_outlined).first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      final call = h.where('DELETE', '/v1/chats/users-access').single;
      expect(call.json['chatName'], 'app_a');
      expect(
          (call.json['members'] as List).single, anyOf('app_bob', 'app_ann'));
      expect(
        h.controller.state.value.rooms.single.members.length,
        2,
      );
      h.dispose();
    });

    testWidgets('a participant cannot add, remove or delete', (tester) async {
      _tall(tester);
      final h = _seeded(
        rooms: const [
          ChatRoom(
            jid: _a,
            title: 'Alpha',
            type: 'group',
            role: 'participant',
            members: [
              ChatRoomMember(xmppUsername: 'app_me'),
              ChatRoomMember(xmppUsername: 'app_bob', firstName: 'Bob'),
            ],
          ),
        ],
      );
      await tester.pumpWidget(_opener(
        h,
        (c) => showRoomInfo(
          c,
          controller: h.controller,
          config: h.controller.config,
          roomJid: _a,
        ),
      ));
      await _open(tester);
      expect(find.text('Add members'), findsNothing);
      expect(find.byIcon(Icons.person_remove_alt_1_outlined), findsNothing);
      expect(find.text('Delete chat'), findsNothing);
      expect(find.text('Leave'), findsOneWidget);
      h.dispose();
    });

    testWidgets('disableRoomConfig makes the profile read only',
        (tester) async {
      _tall(tester);
      const config = ChatComponentConfig(
        appId: 'app',
        baseUrl: 'https://api.test',
        xmppSettings: kSupportSettings,
        disableRoomConfig: true,
      );
      final h = _seeded(config: config);
      await tester.pumpWidget(_opener(
        h,
        (c) => showRoomInfo(
          c,
          controller: h.controller,
          config: config,
          roomJid: _a,
        ),
      ));
      await _open(tester);
      expect(find.text('Add members'), findsNothing);
      expect(find.byIcon(Icons.person_remove_alt_1_outlined), findsNothing);
      expect(find.text('Delete chat'), findsNothing);
      h.dispose();
    });

    testWidgets('notifications switch mutes the room', (tester) async {
      _tall(tester);
      final h = _seeded(
          handler: (r) => r.path.contains('/mute')
              ? jsonResponse({
                  'result': {'muted': r.method == 'PUT'}
                })
              : null);
      await tester.pumpWidget(_opener(
        h,
        (c) => showRoomInfo(
          c,
          controller: h.controller,
          config: h.controller.config,
          roomJid: _a,
        ),
      ));
      await _open(tester);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          true);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(h.where('PUT', '/v1/chats/my/app_a/mute'), hasLength(1));
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          false);
      h.dispose();
    });

    testWidgets('leave confirms, calls the API and closes the sheet',
        (tester) async {
      _tall(tester);
      final h = _seeded();
      await tester.pumpWidget(_opener(
        h,
        (c) => showRoomInfo(
          c,
          controller: h.controller,
          config: h.controller.config,
          roomJid: _a,
        ),
      ));
      await _open(tester);
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(find.text('Leave Chat'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Leave'));
      await tester.pumpAndSettle();
      expect(h.where('DELETE', '/v1/chats/users-access'), hasLength(1));
      expect(find.text('Chat Profile'), findsNothing);
      expect(h.controller.state.value.rooms, isEmpty);
      h.dispose();
    });

    testWidgets('delete confirms and removes the room for everyone',
        (tester) async {
      _tall(tester);
      final h = _seeded();
      await tester.pumpWidget(_opener(
        h,
        (c) => showRoomInfo(
          c,
          controller: h.controller,
          config: h.controller.config,
          roomJid: _a,
        ),
      ));
      await _open(tester);
      await tester.tap(find.text('Delete chat'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this chat ?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(h.where('DELETE', '/v1/chats').single.json, {'name': 'app_a'});
      expect(h.controller.state.value.rooms, isEmpty);
      h.dispose();
    });

    testWidgets('a member the push added without a name is looked up',
        (tester) async {
      _tall(tester);
      final h = _seeded(
        handler: (r) => r.path == '/v1/apps/users/app_new'
            ? jsonResponse({
                'result': {
                  'xmppUsername': 'app_new',
                  'firstName': 'Nina',
                  'lastName': 'West',
                },
              })
            : null,
        rooms: const [
          ChatRoom(
            jid: _a,
            title: 'Alpha',
            type: 'group',
            members: [
              ChatRoomMember(xmppUsername: 'app_me'),
              ChatRoomMember(xmppUsername: 'app_new'),
            ],
          ),
        ],
      );
      await tester.pumpWidget(_opener(
        h,
        (c) => showRoomInfo(
          c,
          controller: h.controller,
          config: h.controller.config,
          roomJid: _a,
        ),
      ));
      await _open(tester);
      await tester.pumpAndSettle();
      expect(find.text('Nina West'), findsOneWidget);
      h.dispose();
    });
  });

  group('message search screen', () {
    ApiHandler results({List<Map<String, dynamic>>? items, int total = 1}) =>
        (r) => r.path == '/v2/apps/app/messages/search'
            ? jsonResponse({
                'items': items ??
                    [
                      {
                        '_id': 'h1',
                        'chatId': 'app_a',
                        'room': _a,
                        'from': 'app_bob@xmpp.test',
                        'fromUserId': 'u-bob',
                        'body': 'say hello world',
                        'stanzaId': '${archiveId(1)}',
                        'messageId': 'x',
                        'createdAt': '2026-07-14T10:00:00Z',
                      },
                    ],
                'total': total,
                'offset': 0,
                'limit': 20,
              })
            : null;

    Future<void> openSearch(
      WidgetTester tester,
      RoomsHarness h, {
      String? roomJid = _a,
    }) async {
      await tester.pumpWidget(_opener(
        h,
        (c) => showMessageSearch(
          c,
          controller: h.controller,
          config: h.controller.config,
          roomJid: roomJid,
        ),
      ));
      await _open(tester);
    }

    testWidgets('does nothing when search is off', (tester) async {
      const off = ChatComponentConfig(
        appId: 'app',
        baseUrl: 'https://api.test',
        xmppSettings: kSupportSettings,
      );
      final h = _seeded(config: off);
      await tester.pumpWidget(_opener(
        h,
        (c) => showMessageSearch(
          c,
          controller: h.controller,
          config: off,
          roomJid: _a,
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Search in this chat'), findsNothing);
      h.dispose();
    });

    testWidgets('hint, too short, then results for this chat', (tester) async {
      final h = _seeded(handler: results());
      await openSearch(tester, h);
      expect(
          find.text('Type to search the conversation history'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'h');
      await tester.pump();
      expect(find.text('Type at least 2 characters'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.where('GET', '/messages/search'), isEmpty); // debounce
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      final call = h.where('GET', '/messages/search').single;
      expect(call.url.queryParameters['q'], 'hello');
      expect(call.url.queryParameters['chatId'], 'app_a');
      expect(call.url.queryParameters['limit'], '20');
      expect(call.url.queryParameters['offset'], '0');
      expect(find.text('1 found'), findsOneWidget);
      expect(find.textContaining('say '), findsOneWidget);
      h.dispose();
    });

    testWidgets('all chats scope drops chatId', (tester) async {
      final h = _seeded(handler: results());
      await openSearch(tester, h);
      await tester.tap(find.text('All chats'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump(const Duration(milliseconds: 500));
      final call = h.where('GET', '/messages/search').single;
      expect(call.url.queryParameters.containsKey('chatId'), false);
      h.dispose();
    });

    testWidgets('without an open chat only "all chats" is available',
        (tester) async {
      final h = _seeded(handler: results());
      await openSearch(tester, h, roomJid: null);
      expect(find.text('Search all chats'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump(const Duration(milliseconds: 500));
      expect(
          h
              .where('GET', '/messages/search')
              .single
              .url
              .queryParameters
              .containsKey('chatId'),
          false);
      h.dispose();
    });

    testWidgets('date filters: validated, sent as day bounds, order checked',
        (tester) async {
      final h = _seeded(handler: results());
      await openSearch(tester, h);
      await tester.tap(find.text('Filters'));
      await tester.pump();
      await tester.enterText(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(TextField),
        ),
        'hello',
      );
      // body fields: sender, since, until
      final fields = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(TextField),
      );
      final since = fields.at(1);
      final until = fields.at(2);

      await tester.enterText(since, '2026-02-31');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      // an invalid day is no bound, and is flagged
      expect(find.text('YYYY-MM-DD'), findsWidgets);
      var call = h.where('GET', '/messages/search').last;
      expect(call.url.queryParameters.containsKey('since'), false);

      await tester.enterText(since, '2026-07-01');
      await tester.enterText(until, '2026-07-14');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      call = h.where('GET', '/messages/search').last;
      expect(DateTime.parse(call.url.queryParameters['since']!).toLocal(),
          DateTime(2026, 7, 1));
      expect(DateTime.parse(call.url.queryParameters['until']!).toLocal(),
          DateTime(2026, 7, 14, 23, 59, 59, 999));

      final before = h.where('GET', '/messages/search').length;
      await tester.enterText(since, '2026-07-20');
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('The start date is after the end date.'), findsWidgets);
      expect(h.where('GET', '/messages/search').length, before); // nothing sent
      h.dispose();
    });

    testWidgets('empty, error with retry and load more', (tester) async {
      var mode = 'empty';
      final h = _seeded(handler: (r) {
        if (r.path != '/v2/apps/app/messages/search') return null;
        if (mode == 'error') return jsonResponse({}, 500);
        if (mode == 'empty') {
          return jsonResponse({'items': [], 'total': 0});
        }
        final offset = int.parse(r.url.queryParameters['offset']!);
        return jsonResponse({
          'items': [
            {
              '_id': 'p$offset',
              'chatId': 'app_a',
              'room': _a,
              'body': 'hello page $offset',
              'createdAt': '2026-07-14T10:00:00Z',
            },
          ],
          'total': 2,
          'offset': offset,
          'limit': 20,
        });
      });
      await openSearch(tester, h);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('No messages found'), findsOneWidget);

      mode = 'error';
      await tester.enterText(find.byType(TextField), 'hello2');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('Search failed.'), findsOneWidget);

      mode = 'pages';
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(find.text('hello page 0'), findsOneWidget);
      await tester.tap(find.text('Show more'));
      await tester.pump();
      await tester.pump();
      expect(find.text('hello page 1'), findsOneWidget);
      expect(find.text('Show more'), findsNothing);
      h.dispose();
    });

    testWidgets('tapping a hit opens the room and jumps, then closes',
        (tester) async {
      final h = _seeded(handler: results());
      await openSearch(tester, h);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.tap(find.textContaining('say '));
      await tester.pumpAndSettle();
      expect(h.controller.state.value.jumpTarget?.messageId, '${archiveId(1)}');
      expect(h.controller.state.value.jumpTarget?.roomJid, _a);
      expect(find.text('Search in this chat'), findsNothing); // page closed
      h.dispose();
    });

    testWidgets('a hit of a room this device does not know is inert',
        (tester) async {
      final h = _seeded(
        handler: results(items: [
          {
            '_id': 'h2',
            'chatId': 'app_unknown',
            'room': 'app_unknown@conference.xmpp.test',
            'body': 'hello elsewhere',
            'createdAt': '2026-07-14T10:00:00Z',
          },
        ]),
      );
      await openSearch(tester, h);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      await tester.tap(find.textContaining('elsewhere'));
      await tester.pumpAndSettle();
      expect(h.controller.state.value.jumpTarget, isNull);
      expect(find.text('Search in this chat'), findsOneWidget); // still open
      h.dispose();
    });
  });
}
