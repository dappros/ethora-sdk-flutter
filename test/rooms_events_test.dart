import 'dart:async';

import 'package:ethora_sdk_flutter/src/core/room_events.dart';
import 'package:ethora_sdk_flutter/src/models/chat_room.dart';
import 'package:ethora_sdk_flutter/src/networking/stanza_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

ParsedEthoraEvent _event(
  String type,
  Map<String, String> attrs, {
  String from = 'admin@xmpp.test',
}) =>
    ParsedEthoraEvent(from: from, type: type, attributes: attrs);

const _domain = 'xmpp.test';

void main() {
  group('isTrustedEthoraSender', () {
    test('the sender must be a bare JID on the session domain', () {
      expect(isTrustedEthoraSender('admin@xmpp.test', _domain), true);
      expect(isTrustedEthoraSender('ADMIN@XMPP.TEST', _domain), true);
      expect(isTrustedEthoraSender('admin@xmpp.test/res', _domain), false);
      expect(isTrustedEthoraSender('admin@other.test', _domain), false);
      expect(
        isTrustedEthoraSender('room@conference.xmpp.test', _domain),
        false,
      );
      expect(isTrustedEthoraSender('', _domain), false);
      expect(isTrustedEthoraSender('a@b@xmpp.test', _domain), false);
    });

    test('a pinned list restricts the senders (full JID or localpart)', () {
      expect(
        isTrustedEthoraSender('admin@xmpp.test', _domain, pinned: ['admin']),
        true,
      );
      expect(
        isTrustedEthoraSender(
          'admin@xmpp.test',
          _domain,
          pinned: ['Admin@XMPP.test'],
        ),
        true,
      );
      expect(
        isTrustedEthoraSender('admin@xmpp.test', _domain, pinned: ['root']),
        false,
      );
      expect(
        isTrustedEthoraSender('admin@xmpp.test', _domain, pinned: const []),
        true,
      );
    });
  });

  group('EthoraEventRouter', () {
    late List<String> refreshedRooms;
    late List<String> refreshedUsers;
    late Set<String> held;
    late DateTime clock;
    var failRefresh = false;
    late EthoraEventRouter router;

    EthoraEventRouter make(
        {Duration debounce = const Duration(milliseconds: 20)}) {
      return EthoraEventRouter(
        holdsRoom: held.contains,
        refreshRoom: (chatName) async {
          refreshedRooms.add(chatName);
          if (failRefresh) throw StateError('boom');
        },
        refreshUser: refreshedUsers.add,
        now: () => clock,
        debounce: debounce,
      );
    }

    bool handle(ParsedEthoraEvent e, {List<String>? trusted}) => router.handle(
          e,
          ownDomain: _domain,
          appId: 'app',
          trustedSenders: trusted,
        );

    setUp(() {
      refreshedRooms = <String>[];
      refreshedUsers = <String>[];
      held = <String>{'app_room1', 'app_room2'};
      clock = DateTime(2026, 1, 1);
      failRefresh = false;
      router = make();
    });
    tearDown(() => router.dispose());

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 80));

    test('user-profile-updated refreshes that user', () {
      final acted = handle(_event('user-profile-updated', {
        'xmppUsername': 'app_u1',
        'appId': 'app',
      }));
      expect(acted, true);
      expect(refreshedUsers, ['app_u1']);
    });

    test('chat-meta-updated refreshes a held room once (debounced)', () async {
      for (var i = 0; i < 5; i++) {
        handle(_event('chat-meta-updated', {
          'chatName': 'app_room1',
          'appId': 'app',
        }));
      }
      expect(refreshedRooms, isEmpty);
      await settle();
      expect(refreshedRooms, ['app_room1']);
    });

    test('a room we do not hold is ignored', () async {
      final acted = handle(_event('chat-meta-updated', {
        'chatName': 'app_unknown',
      }));
      expect(acted, false);
      await settle();
      expect(refreshedRooms, isEmpty);
    });

    test('untrusted sender, foreign appId and unsafe keys are ignored',
        () async {
      handle(_event('chat-meta-updated', {'chatName': 'app_room1'},
          from: 'admin@evil.test'));
      handle(_event('chat-meta-updated', {'chatName': 'app_room1'},
          from: 'room@xmpp.test/nick'));
      handle(_event('chat-meta-updated', {
        'chatName': 'app_room1',
        'appId': 'other',
      }));
      handle(_event('chat-meta-updated', {'chatName': 'room1'}));
      handle(_event('chat-meta-updated', {'chatName': 'app_room1/../x'}));
      handle(_event('user-profile-updated', {'xmppUsername': 'other_u1'}));
      handle(_event('user-profile-updated', {'xmppUsername': 'u1'}));
      handle(_event('user-profile-updated', {'xmppUsername': ''}));
      handle(_event('unknown-type', {'chatName': 'app_room1'}));
      await settle();
      expect(refreshedRooms, isEmpty);
      expect(refreshedUsers, isEmpty);
    });

    test('a pinned sender list is enforced', () async {
      final e = _event('chat-meta-updated', {'chatName': 'app_room1'});
      expect(handle(e, trusted: ['someone-else']), false);
      expect(handle(e, trusted: ['admin']), true);
      await settle();
      expect(refreshedRooms, ['app_room1']);
    });

    test('failures back off 5 s, 30 s, then 120 s per room', () async {
      failRefresh = true;
      final seen = <int>[];
      Future<void> poke() async {
        handle(_event('chat-meta-updated', {'chatName': 'app_room1'}));
        await settle();
        seen.add(refreshedRooms.length);
      }

      await poke(); // fails: 1 call, backs off 5 s
      expect(seen.last, 1);
      expect(router.failureCount('app_room1'), 1);

      clock = clock.add(const Duration(seconds: 4));
      await poke(); // still backing off
      expect(seen.last, 1);

      clock = clock.add(const Duration(seconds: 2)); // 6 s since failure
      await poke(); // fails again: 30 s
      expect(seen.last, 2);
      expect(router.failureCount('app_room1'), 2);

      clock = clock.add(const Duration(seconds: 29));
      await poke();
      expect(seen.last, 2);

      clock = clock.add(const Duration(seconds: 2));
      await poke(); // fails a third time: 120 s
      expect(seen.last, 3);

      clock = clock.add(const Duration(seconds: 100));
      await poke();
      expect(seen.last, 3);

      clock = clock.add(const Duration(seconds: 25));
      failRefresh = false;
      await poke(); // recovers
      expect(seen.last, 4);
      expect(router.failureCount('app_room1'), 0);
    });

    test('backoff is per room', () async {
      failRefresh = true;
      handle(_event('chat-meta-updated', {'chatName': 'app_room1'}));
      await settle();
      failRefresh = false;
      handle(_event('chat-meta-updated', {'chatName': 'app_room2'}));
      await settle();
      expect(refreshedRooms, ['app_room1', 'app_room2']);
    });

    test('an event during a refresh runs once more after it', () async {
      final gate = Completer<void>();
      var calls = 0;
      final slow = EthoraEventRouter(
        holdsRoom: held.contains,
        refreshRoom: (chatName) async {
          calls += 1;
          if (calls == 1) await gate.future;
        },
        refreshUser: (_) {},
        debounce: const Duration(milliseconds: 10),
      );
      final e = _event('chat-meta-updated', {'chatName': 'app_room1'});
      slow.handle(e, ownDomain: _domain, appId: 'app');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(calls, 1);
      slow.handle(e, ownDomain: _domain, appId: 'app');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(calls, 1); // in flight: marked to run again
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, 2);
      slow.dispose();
    });

    test('dispose cancels pending refreshes', () async {
      handle(_event('chat-meta-updated', {'chatName': 'app_room1'}));
      router.dispose();
      await settle();
      expect(refreshedRooms, isEmpty);
    });
  });

  group('parsing of the carrier', () {
    test('an ethora-event headline parses, also inside a MUC-SUB wrapper', () {
      const plain = '<message from="admin@xmpp.test" type="headline">'
          '<ethora-event xmlns="urn:ethora:events:1" type="chat-meta-updated" '
          'chatName="app_r" appId="app"/></message>';
      final e = parseEthoraEventStanza(XmlDocument.parse(plain).rootElement)!;
      expect(e.type, 'chat-meta-updated');
      expect(e.from, 'admin@xmpp.test');
      expect(e.attributes['chatName'], 'app_r');

      const wrapped = '<message from="room@conference.xmpp.test">'
          '<event xmlns="http://jabber.org/protocol/pubsub#event"><items><item>'
          '<message from="admin@xmpp.test" type="headline">'
          '<ethora-event xmlns="urn:ethora:events:1" type="user-profile-updated" '
          'xmppUsername="app_u"/></message></item></items></event></message>';
      final w = parseEthoraEventStanza(XmlDocument.parse(wrapped).rootElement)!;
      expect(w.type, 'user-profile-updated');
      expect(w.from, 'admin@xmpp.test');
    });
  });

  group('membership', () {
    const room = ChatRoom(
      jid: 'r@conference.xmpp.test',
      usersCnt: 2,
      members: [
        ChatRoomMember(xmppUsername: 'app_a'),
        ChatRoomMember(xmppUsername: 'app_b'),
      ],
    );
    ParsedMembership change(String user, String affiliation) =>
        ParsedMembership(
          roomJid: room.jid,
          affiliation: affiliation,
          xmppUsername: user,
        );

    test('a new member is added and counted', () {
      final next = applyMembershipChange(room, change('app_c', 'member'));
      expect(
          next.members.map((m) => m.xmppUsername), ['app_a', 'app_b', 'app_c']);
      expect(next.usersCnt, 3);
    });

    test('a member already listed changes nothing', () {
      final next = applyMembershipChange(room, change('app_a', 'member'));
      expect(identical(next, room), true);
    });

    test('affiliation none or outcast removes and counts down', () {
      for (final aff in ['none', 'outcast']) {
        final next = applyMembershipChange(room, change('app_a', aff));
        expect(next.members.map((m) => m.xmppUsername), ['app_b']);
        expect(next.usersCnt, 1);
      }
    });

    test('a leaver missing from a complete list changes nothing', () {
      final next = applyMembershipChange(room, change('app_zzz', 'none'));
      expect(identical(next, room), true);
    });

    test('a leaver missing from a truncated list still lowers the total', () {
      const big = ChatRoom(
        jid: 'r@conference.xmpp.test',
        usersCnt: 500,
        members: [ChatRoomMember(xmppUsername: 'app_a')],
      );
      final next = applyMembershipChange(big, change('app_zzz', 'none'));
      expect(next.usersCnt, 499);
      expect(next.members, hasLength(1));
    });

    test('a join into a truncated room adjusts the current total', () {
      const big = ChatRoom(
        jid: 'r@conference.xmpp.test',
        usersCnt: 500,
        members: [ChatRoomMember(xmppUsername: 'app_a')],
      );
      final next = applyMembershipChange(big, change('app_new', 'member'));
      expect(next.usersCnt, 501);
      expect(next.members, hasLength(2));
    });

    test('adjustUsersCnt never goes below the loaded members or zero', () {
      const r = ChatRoom(jid: 'r@c', usersCnt: 1, members: [
        ChatRoomMember(xmppUsername: 'a'),
        ChatRoomMember(xmppUsername: 'b'),
      ]);
      expect(adjustUsersCnt(r, -1, 2), 2);
      expect(adjustUsersCnt(const ChatRoom(jid: 'r@c'), -1, 0), 0);
    });

    test('the membership stanza parses (and an invite is not membership)', () {
      const member = '<message from="room@conference.xmpp.test">'
          '<x xmlns="http://jabber.org/protocol/muc#user">'
          '<item jid="app_c@xmpp.test" affiliation="member"/></x></message>';
      final m = parseMembershipStanza(XmlDocument.parse(member).rootElement)!;
      expect(m.roomJid, 'room@conference.xmpp.test');
      expect(m.xmppUsername, 'app_c');
      expect(m.affiliation, 'member');
      const invite = '<message from="room@conference.xmpp.test">'
          '<x xmlns="http://jabber.org/protocol/muc#user">'
          '<invite from="a@xmpp.test"/><item jid="app_c@xmpp.test"/></x></message>';
      expect(
          parseMembershipStanza(XmlDocument.parse(invite).rootElement), isNull);
    });
  });

  test('roleFromAffiliation maps owners and admins to moderator', () {
    expect(roleFromAffiliation('owner'), 'moderator');
    expect(roleFromAffiliation('admin'), 'moderator');
    expect(roleFromAffiliation('member'), 'participant');
    expect(roleFromAffiliation('none'), '');
    expect(roleFromAffiliation(''), '');
  });

  group('kicked presence', () {
    test('110 and 321 together mean removed by the owner', () {
      const kicked =
          '<presence from="room@conference.xmpp.test/me" type="unavailable">'
          '<x xmlns="http://jabber.org/protocol/muc#user">'
          '<item affiliation="none" role="none"/>'
          '<status code="110"/><status code="321"/></x></presence>';
      final p = parsePresenceStanza(XmlDocument.parse(kicked).rootElement)!;
      expect(p.isKicked, true);
      expect(p.roomJid, 'room@conference.xmpp.test');
      const left =
          '<presence from="room@conference.xmpp.test/me" type="unavailable">'
          '<x xmlns="http://jabber.org/protocol/muc#user"><status code="110"/></x></presence>';
      expect(parsePresenceStanza(XmlDocument.parse(left).rootElement)!.isKicked,
          false);
    });
  });

  group('chat meta', () {
    const current = ChatRoom(
      jid: 'app_r@conference.xmpp.test',
      title: 'Old',
      description: 'old description',
      picture: 'old.png',
      usersCnt: 10,
      type: 'group',
      members: [ChatRoomMember(xmppUsername: 'app_a')],
      unreadCount: 4,
    );

    test('updates title, description, picture and type', () {
      final next = applyChatMeta(current, {
        'title': 'New',
        'description': 'new description',
        'picture': 'new.png',
        'type': 'public',
        'usersCnt': 12,
      });
      expect(next.title, 'New');
      expect(next.description, 'new description');
      expect(next.picture, 'new.png');
      expect(next.type, 'public');
      expect(next.usersCnt, 12);
      // members and unread are untouched
      expect(next.members, current.members);
      expect(next.unreadCount, 4);
      expect(next.jid, current.jid);
    });

    test('usersCnt is never lowered', () {
      final next = applyChatMeta(current, {'usersCnt': 3, 'title': 'New'});
      expect(next.usersCnt, 10);
    });

    test('a missing or unknown field never blanks what we have', () {
      final next = applyChatMeta(current, {'type': 'weird'});
      expect(next.title, 'Old');
      expect(next.description, 'old description');
      expect(next.picture, 'old.png');
      expect(next.type, 'group');
    });

    test('a sentinel title on a private chat is replaced by the peer name', () {
      const priv = ChatRoom(jid: 'app_p@conference.xmpp.test', title: 'Bob');
      final next = applyChatMeta(
        priv,
        {
          'type': 'private',
          'title': 'deleted',
          'members': [
            {'xmppUsername': 'app_me', 'firstName': 'Me', 'lastName': 'Self'},
            {
              'xmppUsername': 'app_bob',
              'firstName': 'Bob',
              'lastName': 'Stone'
            },
          ],
        },
        myLocal: 'app_me',
      );
      expect(next.title, 'Bob Stone');
    });

    test('roomTitleFromApi keeps a real title and refuses sentinels', () {
      expect(roomTitleFromApi({'title': ' Team '}), 'Team');
      expect(roomTitleFromApi({'title': ''}), isNull);
      expect(
        roomTitleFromApi({'type': 'private', 'title': 'Deleted User'}),
        'Deleted User',
      );
    });
  });
}
