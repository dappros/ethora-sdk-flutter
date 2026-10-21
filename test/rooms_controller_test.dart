import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:ethora_sdk_flutter/src/networking/stanza_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rooms_support.dart';

const _a = 'app_a@conference.xmpp.test';
const _b = 'app_b@conference.xmpp.test';

RoomsHarness _harness({ApiHandler? handler}) {
  final h = RoomsHarness(
    rooms: const [
      ChatRoom(
        jid: _a,
        title: 'Alpha',
        usersCnt: 2,
        members: [
          ChatRoomMember(xmppUsername: 'app_me'),
          ChatRoomMember(xmppUsername: 'app_bob', firstName: 'Bob'),
        ],
      ),
      ChatRoom(jid: _b, title: 'Beta', usersCnt: 5),
    ],
    handler: handler,
  );
  return h;
}

ChatMessage _msg(String room, int n, String sender) => ChatMessage(
      id: '${archiveId(n)}',
      roomJid: room,
      text: 'hi $n',
      user: ChatUser(xmppUsername: sender, firstName: 'Old'),
      createdAtMs: 1700000000000 + n,
    );

void main() {
  group('mute, report', () {
    test('mute updates the room from the server answer', () async {
      final h = _harness(
          handler: (r) => jsonResponse({
                'result': {'muted': r.method == 'PUT'},
              }));
      await h.start();
      await h.controller.setRoomMuted(_a, true);
      expect(
        h.controller.state.value.rooms.firstWhere((r) => r.jid == _a).muted,
        true,
      );
      await h.controller.setRoomMuted(_a, false);
      expect(
        h.controller.state.value.rooms.firstWhere((r) => r.jid == _a).muted,
        false,
      );
      expect(h.where('PUT', '/v1/chats/my/app_a/mute'), hasLength(1));
      expect(h.where('DELETE', '/v1/chats/my/app_a/mute'), hasLength(1));
      h.dispose();
    });

    test('a failed mute leaves the room as it was and throws', () async {
      final h = _harness(
          handler: (r) =>
              r.path.contains('/mute') ? jsonResponse({}, 500) : null);
      await h.start();
      await expectLater(
        h.controller.setRoomMuted(_a, true),
        throwsA(isA<ApiException>()),
      );
      expect(
        h.controller.state.value.rooms.firstWhere((r) => r.jid == _a).muted,
        false,
      );
      h.dispose();
    });

    test('report posts the category and text for the chat name', () async {
      final h = _harness();
      await h.start();
      await h.controller.reportRoom(_a, category: 'spam', text: 'junk');
      final call = h.where('POST', '/v1/chats/reports/app_a').single;
      expect(call.json, {'category': 'spam', 'text': 'junk'});
      h.dispose();
    });
  });

  group('leave', () {
    test('REST first, then the MUC leave, then it is gone locally', () async {
      final h = _harness();
      await h.start();
      expect(h.controller.state.value.selectedRoomJid, _a);
      final events = <ChatRoomEvent>[];
      h.controller.roomEvents.listen(events.add);

      await h.controller.leaveRoom(_a);

      final call = h.where('DELETE', '/v1/chats/users-access').single;
      expect(call.json, {
        'chatName': 'app_a',
        'members': ['app_me'],
      });
      expect(h.xmpp.leaves, [_a]);
      final state = h.controller.state.value;
      expect(state.rooms.map((r) => r.jid), [_b]);
      expect(state.messagesByRoom.containsKey(_a), false);
      expect(state.selectedRoomJid, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(events.single.type, ChatRoomEventType.left);
      expect(events.single.title, 'Alpha');
      h.dispose();
    });

    test('a 404 is success', () async {
      final h = _harness(
          handler: (r) => r.method == 'DELETE' ? jsonResponse({}, 404) : null);
      await h.start();
      await h.controller.leaveRoom(_b);
      expect(h.controller.state.value.rooms.map((r) => r.jid), [_a]);
      expect(h.xmpp.leaves, [_b]);
      h.dispose();
    });

    test('a failure keeps the chat and does not leave the MUC', () async {
      final h = _harness(
          handler: (r) => r.method == 'DELETE'
              ? jsonResponse({'message': 'no'}, 500)
              : null);
      await h.start();
      await expectLater(
          h.controller.leaveRoom(_b), throwsA(isA<ApiException>()));
      expect(h.controller.state.value.rooms, hasLength(2));
      expect(h.xmpp.leaves, isEmpty);
      h.dispose();
    });

    test('delete room removes it for everyone and locally', () async {
      final h = _harness();
      await h.start();
      await h.controller.deleteRoom(_b);
      final call = h.where('DELETE', '/v1/chats').single;
      expect(call.json, {'name': 'app_b'});
      expect(h.controller.state.value.rooms.map((r) => r.jid), [_a]);
      h.dispose();
    });
  });

  group('members', () {
    test('add: REST, a MUC invite each, then a refresh of the list', () async {
      final h = _harness(handler: (r) {
        if (r.method == 'GET' && r.path == '/v1/chats/my/app_a') {
          return jsonResponse({
            'usersCnt': 3,
            'members': [
              {'xmppUsername': 'app_me'},
              {'xmppUsername': 'app_bob'},
              {'xmppUsername': 'app_new', 'firstName': 'New'},
            ],
          });
        }
        return null;
      });
      await h.start();
      await h.controller.addRoomMembers(_a, ['app_new']);
      expect(h.where('POST', '/v1/chats/users-access').single.json, {
        'chatName': 'app_a',
        'members': ['app_new'],
      });
      expect(h.xmpp.invites, [(_a, 'app_new')]);
      final room =
          h.controller.state.value.rooms.firstWhere((r) => r.jid == _a);
      expect(room.members.map((m) => m.xmppUsername),
          ['app_me', 'app_bob', 'app_new']);
      expect(room.usersCnt, 3);
      h.dispose();
    });

    test('remove: REST and the list and count follow', () async {
      final h = _harness();
      await h.start();
      await h.controller.removeRoomMembers(_a, ['app_bob']);
      expect(h.where('DELETE', '/v1/chats/users-access').single.json, {
        'chatName': 'app_a',
        'members': ['app_bob'],
      });
      final room =
          h.controller.state.value.rooms.firstWhere((r) => r.jid == _a);
      expect(room.members.map((m) => m.xmppUsername), ['app_me']);
      expect(room.usersCnt, 1);
      h.dispose();
    });

    test('lookupUserProfile returns the display fields or null', () async {
      final h = _harness(
          handler: (r) => r.path == '/v1/apps/users/app_bob'
              ? jsonResponse({
                  'result': {'xmppUsername': 'app_bob', 'firstName': 'Bob'},
                })
              : jsonResponse({}, 404));
      await h.start();
      expect(
          (await h.controller.lookupUserProfile('app_bob'))!.firstName, 'Bob');
      expect(await h.controller.lookupUserProfile('app_zed'), isNull);
      h.dispose();
    });
  });

  group('create and join', () {
    test('private chat: POST, adopt, join by presence, hook fired', () async {
      final h = _harness(
          handler: (r) => r.path == '/v1/chats/private'
              ? jsonResponse({
                  'result': {
                    'name': 'app_p',
                    'title': 'deleted',
                    'type': 'private',
                    'members': [
                      {'xmppUsername': 'app_me', 'firstName': 'Me'},
                      {
                        'xmppUsername': 'app_bob',
                        'firstName': 'Bob',
                        'lastName': 'S'
                      },
                    ],
                  },
                })
              : null);
      await h.start();
      final joined = <String>[];
      h.controller.onRoomJoined.add(joined.add);

      final room = await h.controller.createPrivateChat('app_bob');
      expect(h.where('POST', '/v1/chats/private').single.json,
          {'username': 'app_bob'});
      expect(room.jid, 'app_p@conference.xmpp.test');
      expect(room.title, 'Bob S');
      expect(h.controller.state.value.rooms.first.jid, room.jid);
      expect(h.xmpp.presences, contains(room.jid));
      expect(joined, [room.jid]);
      h.dispose();
    });

    test('group chat sends title, type and members', () async {
      final h = _harness(
          handler: (r) => r.path == '/v1/chats' && r.method == 'POST'
              ? jsonResponse({
                  'result': {'name': 'app_g', 'title': 'Team', 'type': 'group'},
                })
              : null);
      await h.start();
      final room = await h.controller.createGroupChat(
        title: 'Team',
        members: ['app_bob'],
      );
      expect(room.title, 'Team');
      expect(h.where('POST', '/v1/chats').first.json['members'], ['app_bob']);
      h.dispose();
    });

    test('joining a public chat joins by presence, no REST join', () async {
      final h = _harness();
      await h.start();
      final chat =
          const PublicChat(name: 'app_pub', title: 'Public', description: 'd');
      final room = await h.controller.joinPublicChat(chat);
      expect(room.jid, 'app_pub@conference.xmpp.test');
      expect(h.xmpp.presences, contains(room.jid));
      expect(h.controller.state.value.selectedRoomJid, room.jid);
      expect(
          h.controller.state.value.rooms.any((r) => r.jid == room.jid), true);
      expect(h.where('POST', '/v1/chats'), isEmpty);
      // a second join of the same chat is just an open
      final again = await h.controller.joinPublicChat(chat);
      expect(again.jid, room.jid);
      expect(h.controller.state.value.rooms.where((r) => r.jid == room.jid),
          hasLength(1));
      h.dispose();
    });

    test('loadPublicChats goes to the directory endpoint', () async {
      final h = _harness(
          handler: (r) => r.path == '/v1/chats/public'
              ? jsonResponse({
                  'items': [
                    {'name': 'app_x', 'title': 'X'},
                  ],
                  'total': 1,
                })
              : null);
      await h.start();
      final page = await h.controller.loadPublicChats();
      expect(page.items.single.name, 'app_x');
      h.dispose();
    });
  });

  group('server pushes', () {
    test('membership message adjusts the members and the count', () async {
      final h = _harness();
      await h.start();
      h.xmpp.onMembership?.call(const ParsedMembership(
        roomJid: _a,
        affiliation: 'member',
        xmppUsername: 'app_carl',
      ));
      var room = h.controller.state.value.rooms.firstWhere((r) => r.jid == _a);
      expect(room.usersCnt, 3);
      expect(room.members.last.xmppUsername, 'app_carl');

      h.xmpp.onMembership?.call(const ParsedMembership(
        roomJid: _a,
        affiliation: 'none',
        xmppUsername: 'app_bob',
      ));
      room = h.controller.state.value.rooms.firstWhere((r) => r.jid == _a);
      expect(room.usersCnt, 2);
      expect(room.members.map((m) => m.xmppUsername), ['app_me', 'app_carl']);

      // a room we do not hold is ignored
      h.xmpp.onMembership?.call(const ParsedMembership(
        roomJid: 'zzz@conference.xmpp.test',
        affiliation: 'member',
        xmppUsername: 'app_x',
      ));
      expect(h.controller.state.value.rooms, hasLength(2));
      h.dispose();
    });

    test('my own join echo records my role in the room', () async {
      final h = _harness();
      await h.start();
      expect(
        h.controller.state.value.rooms.firstWhere((r) => r.jid == _a).canManage,
        false,
      );
      h.xmpp.onPresence?.call(const ParsedPresence(
        roomJid: _a,
        nick: 'app_me',
        unavailable: false,
        statusCodes: {'110'},
        affiliation: 'owner',
      ));
      var room = h.controller.state.value.rooms.firstWhere((r) => r.jid == _a);
      expect(room.role, 'moderator');
      expect(room.canManage, true);

      h.xmpp.onPresence?.call(const ParsedPresence(
        roomJid: _b,
        nick: 'app_me',
        unavailable: false,
        statusCodes: {'110'},
        affiliation: 'member',
      ));
      room = h.controller.state.value.rooms.firstWhere((r) => r.jid == _b);
      expect(room.role, 'participant');
      expect(room.canManage, false);

      // someone else's presence says nothing about me
      h.xmpp.onPresence?.call(const ParsedPresence(
        roomJid: _b,
        nick: 'app_bob',
        unavailable: false,
        statusCodes: <String>{},
        affiliation: 'owner',
      ));
      expect(
        h.controller.state.value.rooms.firstWhere((r) => r.jid == _b).role,
        'participant',
      );
      h.dispose();
    });

    test('kicked presence removes the room and notifies', () async {
      final h = _harness();
      await h.start();
      final events = <ChatRoomEvent>[];
      h.controller.roomEvents.listen(events.add);
      expect(h.controller.state.value.selectedRoomJid, _a);

      h.xmpp.onPresence?.call(const ParsedPresence(
        roomJid: _a,
        nick: 'app_me',
        unavailable: true,
        statusCodes: {'110', '321'},
        affiliation: 'none',
      ));
      await Future<void>.delayed(Duration.zero);
      final state = h.controller.state.value;
      expect(state.rooms.map((r) => r.jid), [_b]);
      expect(state.selectedRoomJid, isNull);
      expect(events.single.type, ChatRoomEventType.kicked);
      expect(events.single.title, 'Alpha');

      // someone else leaving, or a plain unavailable, is not a kick
      h.xmpp.onPresence?.call(const ParsedPresence(
        roomJid: _b,
        nick: 'x',
        unavailable: true,
        statusCodes: {'110'},
        affiliation: 'none',
      ));
      expect(h.controller.state.value.rooms.map((r) => r.jid), [_b]);
      h.dispose();
    });

    test('chat-meta-updated re-reads the room and never lowers usersCnt',
        () async {
      final h = _harness(
          handler: (r) => r.path == '/v1/chats/my/app_a'
              ? jsonResponse({
                  'title': 'Alpha 2',
                  'description': 'fresh',
                  'usersCnt': 1,
                  'type': 'public',
                })
              : null);
      await h.start();
      h.xmpp.onEthoraEvent?.call(const ParsedEthoraEvent(
        from: 'admin@xmpp.test',
        type: 'chat-meta-updated',
        attributes: {'chatName': 'app_a', 'appId': 'app'},
      ));
      expect(h.where('GET', '/v1/chats/my/app_a'), isEmpty); // debounced
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(h.where('GET', '/v1/chats/my/app_a'), hasLength(1));
      final room =
          h.controller.state.value.rooms.firstWhere((r) => r.jid == _a);
      expect(room.title, 'Alpha 2');
      expect(room.description, 'fresh');
      expect(room.type, 'public');
      expect(room.usersCnt, 2);
      expect(room.members, hasLength(2));
      h.dispose();
    });

    test('an untrusted or foreign-app event does nothing', () async {
      final h = _harness();
      await h.start();
      h.xmpp.onEthoraEvent?.call(const ParsedEthoraEvent(
        from: 'admin@evil.test',
        type: 'chat-meta-updated',
        attributes: {'chatName': 'app_a', 'appId': 'app'},
      ));
      h.xmpp.onEthoraEvent?.call(const ParsedEthoraEvent(
        from: 'admin@xmpp.test',
        type: 'chat-meta-updated',
        attributes: {'chatName': 'app_a', 'appId': 'someone-else'},
      ));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(h.where('GET', '/v1/chats/my/app_a'), isEmpty);
      h.dispose();
    });

    test('trustedEventSenders pins the sender', () async {
      final h = RoomsHarness(
        config: const ChatComponentConfig(
          appId: 'app',
          baseUrl: 'https://api.test',
          xmppSettings: kSupportSettings,
          trustedEventSenders: ['root'],
        ),
        rooms: const [ChatRoom(jid: _a, title: 'Alpha')],
        handler: (r) => r.path == '/v1/chats/my/app_a'
            ? jsonResponse({'title': 'X'})
            : null,
      );
      await h.start();
      h.xmpp.onEthoraEvent?.call(const ParsedEthoraEvent(
        from: 'admin@xmpp.test',
        type: 'chat-meta-updated',
        attributes: {'chatName': 'app_a'},
      ));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(h.where('GET', '/v1/chats/my/app_a'), isEmpty);
      h.xmpp.onEthoraEvent?.call(const ParsedEthoraEvent(
        from: 'root@xmpp.test',
        type: 'chat-meta-updated',
        attributes: {'chatName': 'app_a'},
      ));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(h.where('GET', '/v1/chats/my/app_a'), hasLength(1));
      h.dispose();
    });

    test(
        'user-profile-updated refreshes the name in loaded messages and members',
        () async {
      final h = _harness(
          handler: (r) => r.path == '/v1/apps/users/app_bob'
              ? jsonResponse({
                  'result': {
                    '_id': 'idb',
                    'xmppUsername': 'app_bob',
                    'firstName': 'Robert',
                    'lastName': 'Stone',
                    'profileImage': 'new.png',
                  },
                })
              : null);
      await h.start();
      h.xmpp.onMessage?.call(_msg(_a, 1, 'app_bob'));
      h.xmpp.onMessage?.call(_msg(_a, 2, 'app_other'));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      h.xmpp.onEthoraEvent?.call(const ParsedEthoraEvent(
        from: 'admin@xmpp.test',
        type: 'user-profile-updated',
        attributes: {'xmppUsername': 'app_bob', 'appId': 'app'},
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final state = h.controller.state.value;
      final list = state.messagesByRoom[_a]!;
      final bobs = list.where((m) => m.user.xmppUsername == 'app_bob').single;
      expect(bobs.user.firstName, 'Robert');
      expect(bobs.user.lastName, 'Stone');
      expect(bobs.user.photoUrl, 'new.png');
      expect(
          list
              .where((m) => m.user.xmppUsername == 'app_other')
              .single
              .user
              .firstName,
          'Old');
      final member = state.rooms
          .firstWhere((r) => r.jid == _a)
          .members
          .firstWhere((m) => m.xmppUsername == 'app_bob');
      expect(member.firstName, 'Robert');
      h.dispose();
    });
  });
}
