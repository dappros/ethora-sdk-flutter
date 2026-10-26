import 'package:ethora_sdk_flutter/src/models/chat_component_config.dart';
import 'package:ethora_sdk_flutter/src/networking/message_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isMessageSearchEnabled', () {
    test('needs the opt-in flag and an appId', () {
      expect(isMessageSearchEnabled(null), false);
      expect(isMessageSearchEnabled(const ChatComponentConfig()), false);
      expect(
        isMessageSearchEnabled(const ChatComponentConfig(appId: 'app')),
        false,
      );
      expect(
        isMessageSearchEnabled(
          const ChatComponentConfig(enableMessageSearch: true),
        ),
        false,
      );
      expect(
        isMessageSearchEnabled(const ChatComponentConfig(
          enableMessageSearch: true,
          appId: ' ',
        )),
        false,
      );
      expect(
        isMessageSearchEnabled(const ChatComponentConfig(
          enableMessageSearch: true,
          appId: 'app',
        )),
        true,
      );
    });

    test('disableMessageSearch is a hard off', () {
      expect(
        isMessageSearchEnabled(const ChatComponentConfig(
          enableMessageSearch: true,
          disableMessageSearch: true,
          appId: 'app',
        )),
        false,
      );
    });
  });

  group('buildMessageSearchQuery', () {
    test('minimal query has q, limit and offset only', () {
      expect(
        buildMessageSearchQuery(q: 'hello'),
        {'q': 'hello', 'limit': '20', 'offset': '0'},
      );
    });

    test('adds the filters that are set and skips empty ones', () {
      final query = buildMessageSearchQuery(
        q: 'hi',
        chatId: 'app_room',
        fromUserId: 'u1',
        since: '2026-07-14T00:00:00.000Z',
        until: '',
        limit: 5,
        offset: 40,
      );
      expect(query, {
        'q': 'hi',
        'limit': '5',
        'offset': '40',
        'chatId': 'app_room',
        'fromUserId': 'u1',
        'since': '2026-07-14T00:00:00.000Z',
      });
    });
  });

  group('parseMessageSearchPage', () {
    Map<String, dynamic> hit(String id, {String? body, String? deletedAt}) =>
        <String, dynamic>{
          '_id': id,
          'chatId': 'app_room',
          'chatType': 'group',
          'room': 'app_room@conference.x',
          'from': 'app_u1@xmpp.x',
          'fromUserId': 'u1',
          'body': body ?? 'hello $id',
          'messageId': 'm$id',
          'stanzaId': 's$id',
          'createdAt': '2026-07-14T10:00:00.000Z',
          'deletedAt': deletedAt,
        };

    test('drops deleted and empty rows but counts them for paging', () {
      final page = parseMessageSearchPage(
        <String, dynamic>{
          'items': [
            hit('1'),
            hit('2', deletedAt: '2026-07-15T00:00:00Z'),
            hit('3', body: ''),
            hit('4'),
          ],
          'total': 57,
          'offset': 20,
          'limit': 20,
        },
        offset: 20,
      );
      expect(page.items.map((h) => h.id), ['1', '4']);
      // nextOffset counts every raw row, not the filtered ones
      expect(page.nextOffset, 24);
      expect(page.total, 57);
      expect(page.offset, 20);
    });

    test('maps the fields and tolerates a missing items list', () {
      final page = parseMessageSearchPage(
        <String, dynamic>{
          'items': [hit('1')],
        },
      );
      final h = page.items.single;
      expect(h.chatId, 'app_room');
      expect(h.room, 'app_room@conference.x');
      expect(h.fromUserId, 'u1');
      expect(h.stanzaId, 's1');
      expect(h.createdAtDate, DateTime.utc(2026, 7, 14, 10));
      expect(parseMessageSearchPage(<String, dynamic>{}).items, isEmpty);
    });

    test('hit key falls back to content when the row has no id', () {
      final a = parseMessageSearchPage(<String, dynamic>{
        'items': [
          <String, dynamic>{
            'chatId': 'c',
            'body': 'same text here',
            'createdAt': '1'
          },
          <String, dynamic>{
            'chatId': 'c',
            'body': 'same text here',
            'createdAt': '2'
          },
        ],
      }).items;
      expect(a[0].key, isNot(a[1].key));
    });
  });
}
