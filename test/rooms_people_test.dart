import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const rooms = [
    ChatRoom(jid: 'a@c', members: [
      ChatRoomMember(xmppUsername: 'app_me', firstName: 'Me'),
      ChatRoomMember(
        xmppUsername: 'app_bob',
        id: 'u-bob',
        firstName: 'Bob',
        lastName: 'Stone',
      ),
      ChatRoomMember(xmppUsername: 'app_zed'),
    ]),
    ChatRoom(jid: 'b@c', members: [
      ChatRoomMember(xmppUsername: 'APP_BOB', firstName: 'Bob'),
      ChatRoomMember(xmppUsername: 'app_ann', firstName: 'Ann'),
      ChatRoomMember(xmppUsername: ''),
    ]),
  ];

  test('collectKnownPeople: once each, sorted by name, never me', () {
    final people = collectKnownPeople(rooms, myLocal: 'app_me');
    expect(people.map((p) => p.name), ['Ann', 'app_zed', 'Bob Stone']);
    expect(people[2].xmppUsername, 'app_bob');
    expect(people[2].userId, 'u-bob');
  });

  test('filterPeople: names that start with it come first', () {
    final people = collectKnownPeople(rooms, myLocal: 'app_me');
    expect(filterPeople(people, 'an').map((p) => p.name), ['Ann']);
    expect(filterPeople(people, 'o').map((p) => p.name), ['Bob Stone']);
    expect(filterPeople(people, 'p_z').map((p) => p.name), ['app_zed']);
    expect(filterPeople(people, 'zed').map((p) => p.name), ['app_zed']);
    expect(filterPeople(people, '').length, 3);
    expect(filterPeople(people, '', limit: 1), hasLength(1));
    expect(filterPeople(people, 'nobody'), isEmpty);
  });
}
