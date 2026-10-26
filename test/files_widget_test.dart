import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rooms_support.dart';

const _a = 'app_a@conference.xmpp.test';

Map<String, dynamic> _row(String id, String name, String mime,
        {String room = '', int size = 2048}) =>
    {
      '_id': id,
      'location': 'https://files.test/$id',
      'originalname': name,
      'mimetype': mime,
      'size': size,
      'roomName': room,
      'createdAt': '2026-07-14T10:00:00Z',
    };

ApiHandler _files(List<Map<String, dynamic>> rows,
        {int? total, int pageSize = 50}) =>
    (r) {
      if (r.path == '/v2/files' && r.method == 'GET') {
        final offset = int.parse(r.url.queryParameters['offset']!);
        return jsonResponse({
          'items': rows.skip(offset).take(pageSize).toList(),
          'pagination': {'total': total ?? rows.length},
        });
      }
      return null;
    };

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
          ChatRoom(jid: _a, title: 'Alpha', role: 'moderator', type: 'group'),
        ],
    selectedRoomJid: _a,
  );
  return h;
}

Widget _panel(RoomsHarness h) => MaterialApp(
      home: Scaffold(
        body: ChatFilesPanel(
            controller: h.controller, config: h.controller.config),
      ),
    );

Widget _list(RoomsHarness h, {ChatComponentConfig? config}) => MaterialApp(
      home: Scaffold(
        body: RoomListView(
          controller: h.controller,
          config: config ?? h.controller.config,
          selectedRoomJid: _a,
          onSelectRoom: (_) {},
        ),
      ),
    );

void main() {
  group('ChatFilesPanel', () {
    final rows = [
      _row('f1', 'holiday.png', 'image/png'),
      _row('f2', 'report.pdf', 'application/pdf'),
      _row('f3', 'song.mp3', 'audio/mpeg'),
    ];

    testWidgets('lists the files with size and date', (tester) async {
      final h = _seeded(handler: _files(rows));
      await tester.pumpWidget(_panel(h));
      expect(find.text('Loading files...'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('holiday.png'), findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.textContaining('2.0 KB'), findsWidgets);
      expect(h.where('GET', '/v2/files').single.url.queryParameters,
          {'limit': '50', 'offset': '0'});
      h.dispose();
    });

    testWidgets('chips filter by category and search by name', (tester) async {
      final h = _seeded(handler: _files(rows));
      await tester.pumpWidget(_panel(h));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Audio'));
      await tester.pump();
      expect(find.text('song.mp3'), findsOneWidget);
      expect(find.text('holiday.png'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'rep');
      await tester.pump();
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('song.mp3'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(find.text('No files match your search'), findsOneWidget);
      h.dispose();
    });

    testWidgets('empty state', (tester) async {
      final h = _seeded(handler: _files(const []));
      await tester.pumpWidget(_panel(h));
      await tester.pumpAndSettle();
      expect(find.text('No files yet'), findsOneWidget);
      expect(find.text('Files you upload will show up here.'), findsOneWidget);
      h.dispose();
    });

    testWidgets('error state retries', (tester) async {
      var fail = true;
      final h = _seeded(handler: (r) {
        if (r.path != '/v2/files') return null;
        return fail ? jsonResponse({}, 500) : _files(rows)(r);
      });
      await tester.pumpWidget(_panel(h));
      await tester.pumpAndSettle();
      expect(find.text('Could not load files'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('holiday.png'), findsOneWidget);
      h.dispose();
    });

    testWidgets('load more fetches the next page', (tester) async {
      final many = [
        for (var i = 0; i < 5; i++) _row('f$i', 'file$i.png', 'image/png'),
      ];
      final h = _seeded(handler: _files(many, pageSize: 3));
      await tester.pumpWidget(_panel(h));
      await tester.pumpAndSettle();
      expect(find.text('file0.png'), findsOneWidget);
      expect(find.text('file4.png'), findsNothing);
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(
          h.where('GET', '/v2/files').last.url.queryParameters['offset'], '3');
      expect(find.text('file4.png'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
      h.dispose();
    });

    testWidgets('a filter with no match offers the next page', (tester) async {
      final many = [
        for (var i = 0; i < 3; i++) _row('f$i', 'file$i.png', 'image/png'),
        _row('f9', 'song.mp3', 'audio/mpeg'),
      ];
      final h = _seeded(handler: _files(many, pageSize: 3));
      await tester.pumpWidget(_panel(h));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Audio'));
      await tester.pump();
      expect(
        find.text('Not every file is loaded yet, load more to keep searching'),
        findsOneWidget,
      );
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(find.text('song.mp3'), findsOneWidget);
      h.dispose();
    });

    testWidgets('delete asks first, then calls DELETE /v2/files/{id}',
        (tester) async {
      final h = _seeded(handler: _files(rows));
      await tester.pumpWidget(_panel(h));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(find.text('Delete file?'), findsOneWidget);
      expect(h.where('DELETE', '/v2/files'), isEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(h.where('DELETE', '/v2/files/f1'), hasLength(1));
      expect(find.text('holiday.png'), findsNothing);
      h.dispose();
    });

    testWidgets('cancel keeps the file; a failed delete brings it back',
        (tester) async {
      final h = _seeded(
          handler: (r) =>
              r.method == 'DELETE' ? jsonResponse({}, 500) : _files(rows)(r));
      await tester.pumpWidget(_panel(h));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.where('DELETE', '/v2/files'), isEmpty);

      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('holiday.png'), findsOneWidget); // rolled back
      h.dispose();
    });
  });

  group('Chats / Files tabs on the room list', () {
    testWidgets('the toggle switches to the files panel and back',
        (tester) async {
      final h =
          _seeded(handler: _files([_row('f1', 'holiday.png', 'image/png')]));
      await tester.pumpWidget(_list(h));
      expect(find.text('Chats'), findsOneWidget);
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(h.where('GET', '/v2/files'), isEmpty); // not fetched until opened

      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      expect(find.text('holiday.png'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);

      await tester.tap(find.text('Chats'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      h.dispose();
    });

    testWidgets('filesTab.enabled false hides the toggle', (tester) async {
      const config = ChatComponentConfig(
        appId: 'app',
        baseUrl: 'https://api.test',
        xmppSettings: kSupportSettings,
        filesTab: FilesTabConfig(enabled: false),
      );
      final h = _seeded(config: config);
      await tester.pumpWidget(_list(h, config: config));
      expect(find.text('Files'), findsNothing);
      h.dispose();
    });

    testWidgets('the tab hides itself when the backend has no /v2/files',
        (tester) async {
      final h = _seeded(
          handler: (r) => r.path == '/v2/files' ? jsonResponse({}, 404) : null);
      await tester.pumpWidget(_list(h));
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      // 404: the tab is gone and the chats are back
      expect(find.text('Files'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      h.dispose();
    });

    testWidgets('enabled true keeps the tab even after a 404', (tester) async {
      const config = ChatComponentConfig(
        appId: 'app',
        baseUrl: 'https://api.test',
        xmppSettings: kSupportSettings,
        filesTab: FilesTabConfig(enabled: true),
      );
      final h = _seeded(
        config: config,
        handler: (r) => r.path == '/v2/files' ? jsonResponse({}, 404) : null,
      );
      await tester.pumpWidget(_list(h, config: config));
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      expect(find.text('Files'), findsOneWidget);
      expect(find.text('Could not load files'), findsOneWidget);
      h.dispose();
    });
  });

  group('encrypted rooms', () {
    testWidgets('a lock shows on an e2ee room in the list', (tester) async {
      final h = _seeded(rooms: const [
        ChatRoom(jid: _a, title: 'Alpha', e2ee: true),
        ChatRoom(jid: 'app_b@conference.xmpp.test', title: 'Beta'),
      ]);
      await tester.pumpWidget(_list(h));
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
      expect(find.byTooltip('End-to-end encrypted'), findsOneWidget);
      h.dispose();
    });

    testWidgets('new chat offers the encrypted option only when e2ee is on',
        (tester) async {
      Future<RoomsHarness> open(
          WidgetTester tester, ChatComponentConfig cfg) async {
        final h = _seeded(config: cfg);
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showNewChatSheet(
                  context,
                  controller: h.controller,
                  config: cfg,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        return h;
      }

      const off = ChatComponentConfig(
        appId: 'app',
        baseUrl: 'https://api.test',
        xmppSettings: kSupportSettings,
      );
      var h = await open(tester, off);
      expect(find.byKey(const ValueKey('new-chat-e2ee')), findsNothing);
      h.dispose();

      const on = ChatComponentConfig(
        appId: 'app',
        baseUrl: 'https://api.test',
        xmppSettings: kSupportSettings,
        e2ee: E2eeConfig(enabled: true),
      );
      await tester.pumpWidget(const SizedBox());
      h = await open(tester, on);
      expect(find.byKey(const ValueKey('new-chat-e2ee')), findsOneWidget);
      h.dispose();
    });

    testWidgets('with the switch on, the private chat is created encrypted',
        (tester) async {
      const cfg = ChatComponentConfig(
        appId: 'app',
        baseUrl: 'https://api.test',
        xmppSettings: kSupportSettings,
        e2ee: E2eeConfig(enabled: true),
      );
      final h = _seeded(
        config: cfg,
        handler: (r) => r.path == '/v1/chats/private'
            ? jsonResponse({
                'result': {'name': 'app_p', 'type': 'private', 'e2ee': true},
              })
            : null,
        rooms: const [
          ChatRoom(jid: _a, title: 'Alpha', members: [
            ChatRoomMember(xmppUsername: 'app_bob', firstName: 'Bob'),
          ]),
        ],
      );
      ChatRoom? created;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async => created = await showNewChatSheet(
                context,
                controller: h.controller,
                config: cfg,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-chat-e2ee')));
      await tester.pump();
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(h.where('POST', '/v1/chats/private').single.json,
          {'username': 'app_bob', 'e2ee': true});
      expect(created?.e2ee, true);
      h.dispose();
    });
  });

  group('room info', () {
    Widget host(RoomsHarness h) => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showRoomInfo(
                  context,
                  controller: h.controller,
                  config: h.controller.config,
                  roomJid: _a,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );

    testWidgets('shows only this chat\'s files, six first, then all',
        (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rows = [
        for (var i = 0; i < 8; i++)
          _row('r$i', 'room$i.png', 'image/png', room: 'app_a'),
        _row('x1', 'elsewhere.png', 'image/png', room: 'app_b'),
      ];
      final h = _seeded(handler: _files(rows));
      await tester.pumpWidget(host(h));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('FILES'), findsOneWidget);
      expect(find.text('room0.png'), findsOneWidget);
      expect(find.text('room5.png'), findsOneWidget);
      expect(find.text('room6.png'), findsNothing);
      expect(find.text('elsewhere.png'), findsNothing);

      await tester.tap(find.text('Show all'));
      await tester.pump();
      expect(find.text('room7.png'), findsOneWidget);
      await tester.tap(find.text('Show less'));
      await tester.pump();
      expect(find.text('room7.png'), findsNothing);
      h.dispose();
    });

    testWidgets('no files for the chat says so', (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = _seeded(
          handler: _files([_row('x1', 'a.png', 'image/png', room: 'app_b')]));
      await tester.pumpWidget(host(h));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('No files in this chat yet'), findsOneWidget);
      h.dispose();
    });

    testWidgets('no files section when the backend has no files route',
        (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = _seeded(
          handler: (r) => r.path == '/v2/files' ? jsonResponse({}, 404) : null);
      await tester.pumpWidget(host(h));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('FILES'), findsNothing);
      h.dispose();
    });

    testWidgets('a moderator can change the picture, a participant cannot',
        (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var h = _seeded(handler: _files(const []));
      await tester.pumpWidget(host(h));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-picture-pick')), findsOneWidget);
      expect(find.byKey(const ValueKey('room-picture-remove')), findsNothing);
      h.dispose();

      await tester.pumpWidget(const SizedBox());
      h = _seeded(handler: _files(const []), rooms: const [
        ChatRoom(
          jid: _a,
          title: 'Alpha',
          role: 'moderator',
          type: 'group',
          picture: 'https://files.test/pic.png',
        ),
      ]);
      await tester.pumpWidget(host(h));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-picture-remove')), findsOneWidget);
      h.dispose();

      await tester.pumpWidget(const SizedBox());
      h = _seeded(handler: _files(const []), rooms: const [
        ChatRoom(jid: _a, title: 'Alpha', role: 'participant', type: 'group'),
      ]);
      await tester.pumpWidget(host(h));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('room-picture-pick')), findsNothing);
      h.dispose();
    });

    testWidgets('removing the picture calls the API', (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = _seeded(handler: _files(const []), rooms: const [
        ChatRoom(
          jid: _a,
          title: 'Alpha',
          role: 'moderator',
          type: 'group',
          picture: 'https://files.test/pic.png',
        ),
      ]);
      await tester.pumpWidget(host(h));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('room-picture-remove')));
      await tester.pumpAndSettle();
      expect(
          h.where('PATCH', '/v1/chats/my/app_a').single.json, {'picture': ''});
      expect(h.controller.state.value.rooms.single.picture, '');
      h.dispose();
    });

    testWidgets('an encrypted room shows the lock', (tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = _seeded(handler: _files(const []), rooms: const [
        ChatRoom(jid: _a, title: 'Alpha', e2ee: true, type: 'private'),
      ]);
      await tester.pumpWidget(host(h));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
      h.dispose();
    });
  });
}
