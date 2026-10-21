import '../models/chat_room.dart';
import '../networking/stanza_parser.dart';

/// A person the reader can start a chat with or add to a group.
class RoomPerson {
  const RoomPerson({
    required this.xmppUsername,
    required this.userId,
    required this.name,
  });

  /// `appId_userId`, what the REST API takes as a member.
  final String xmppUsername;

  /// The user's `_id`, empty while unknown.
  final String userId;
  final String name;
}

/// Everyone who shares a room with the reader, once each, by name (web
/// `extractUniqueMembersFromRooms`). The reader is left out.
List<RoomPerson> collectKnownPeople(
  Iterable<ChatRoom> rooms, {
  String myLocal = '',
}) {
  final me = myLocal.toLowerCase();
  final seen = <String>{};
  final people = <RoomPerson>[];
  for (final room in rooms) {
    for (final member in room.members) {
      final username = member.xmppUsername.trim();
      if (username.isEmpty) continue;
      final key = localPart(username).toLowerCase();
      if (key == me || !seen.add(key)) continue;
      people.add(RoomPerson(
        xmppUsername: username,
        userId: member.id,
        name: member.displayName,
      ));
    }
  }
  people.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return people;
}

/// People whose name or username contains [needle], names that START with it
/// first. An empty needle returns the first [limit] people.
List<RoomPerson> filterPeople(
  List<RoomPerson> people,
  String needle, {
  int limit = 30,
}) {
  final wanted = needle.trim().toLowerCase();
  if (wanted.isEmpty) return people.take(limit).toList();
  final starts = <RoomPerson>[];
  final contains = <RoomPerson>[];
  for (final person in people) {
    final name = person.name.toLowerCase();
    final at = name.indexOf(wanted);
    if (at == 0) {
      starts.add(person);
    } else if (at > 0 || person.xmppUsername.toLowerCase().contains(wanted)) {
      contains.add(person);
    }
  }
  return <RoomPerson>[...starts, ...contains].take(limit).toList();
}
