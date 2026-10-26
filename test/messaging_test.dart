import 'dart:async';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:ethora_sdk_flutter/src/core/emoji.dart';
import 'package:ethora_sdk_flutter/src/core/message_reference.dart';
import 'package:ethora_sdk_flutter/src/core/receipts.dart';
import 'package:ethora_sdk_flutter/src/core/translation.dart';
import 'package:ethora_sdk_flutter/src/i18n/chat_i18n.dart';
import 'package:ethora_sdk_flutter/src/networking/stanza_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const _room = 'room@conference.xmpp.test';
const _settings = XmppSettings(
  xmppServerUrl: 'wss://xmpp.test/ws',
  host: 'xmpp.test',
  conference: 'conference.xmpp.test',
);

ChatMessage _msg(
  String id, {
  String sender = 'bob',
  int at = 1000,
  String text = 'hi',
  bool isReply = false,
  bool showInChannel = true,
  String? mainMessage,
  Map<String, ChatReaction> reactions = const <String, ChatReaction>{},
}) {
  return ChatMessage(
    id: id,
    xmppId: 'x$id',
    roomJid: _room,
    text: text,
    user: ChatUser(id: sender, username: sender, xmppUsername: sender),
    createdAtMs: at,
    timestamp: at,
    isReply: isReply,
    showInChannel: showInChannel,
    mainMessage: mainMessage,
    reactions: reactions,
  );
}

Future<(ChatComponentController, FakeXmppClient)> _boot({
  ChatComponentConfig? config,
  List<ChatRoom>? rooms,
}) async {
  final store = InMemoryStore()
    ..user = const ChatUser(
      id: 'me',
      username: 'me',
      firstName: 'Me',
      token: 't',
      refreshToken: 'r',
      xmppUsername: 'me',
      xmppPassword: 'p',
    );
  final fake = FakeXmppClient(
    settings: _settings,
    user: store.user!,
    log: (_) {},
  );
  final controller = ChatComponentController(
    config: config ?? const ChatComponentConfig(xmppSettings: _settings),
    store: store,
    authService: FakeAuthService(),
    roomsService: FakeRoomsService(
      rooms: rooms ?? const [ChatRoom(jid: _room, title: 'Room')],
    ),
    xmppClientFactory: ({required settings, required user, required log}) =>
        fake,
  );
  await controller.initialize();
  return (controller, fake);
}

void main() {
  group('message reference', () {
    test('createMainMessage round trips through parseMessageReference', () {
      final strings = ChatStrings.resolve('en', null);
      final json =
          createMainMessage(_msg('1712000000000001', text: 'parent'), strings);
      final ref = parseMessageReference(json)!;
      expect(ref.id, '1712000000000001');
      expect(ref.text, 'parent');
      expect(ref.userName, 'bob');
      expect(ref.roomJid, _room);
    });

    test('media parent reads as its caption or kind', () {
      final strings = ChatStrings.resolve('en', null);
      final photo = _msg('1').copyWith(
        isMedia: true,
        mimeType: 'image/png',
        data: const <String, String>{},
      );
      expect(mediaLabel(photo, strings), 'Photo');
      final captioned = photo.copyWith(data: const {'caption': 'sunset'});
      expect(mediaLabel(captioned, strings), 'sunset');
    });

    test('parse tolerates garbage', () {
      expect(parseMessageReference(null), isNull);
      expect(parseMessageReference(''), isNull);
      expect(parseMessageReference('not json'), isNull);
      expect(parseMessageReference('[1,2]'), isNull);
    });

    test('replyParentId is null for channel-shared replies', () {
      const ref = '{"id":"99","text":"p"}';
      expect(
        replyParentId(
            _msg('1', isReply: true, showInChannel: false, mainMessage: ref)),
        '99',
      );
      expect(
        replyParentId(
            _msg('1', isReply: true, showInChannel: true, mainMessage: ref)),
        isNull,
      );
      expect(
          threadParentId(
              _msg('1', isReply: true, showInChannel: true, mainMessage: ref)),
          '99');
      expect(replyParentId(_msg('1')), isNull);
    });
  });

  group('emoji', () {
    test('shortcodes resolve to glyphs', () {
      expect(emojiGlyph('heart'), '❤️');
      expect(emojiGlyph('+1'), '👍');
      expect(emojiGlyph('not-a-code'), 'not-a-code');
      expect(isKnownEmoji('joy'), true);
    });

    test('quick bar defaults and clamps to 8', () {
      expect(resolveQuickReactions(null), kDefaultQuickReactions);
      expect(resolveQuickReactions(const <String>[]), kDefaultQuickReactions);
      final many = List<String>.generate(12, (i) => 'e$i');
      expect(resolveQuickReactions(many), many.take(8).toList());
    });

    test('search matches id and name', () {
      expect(searchEmojis('heart_eyes').any((e) => e.id == 'heart_eyes'), true);
      expect(searchEmojis('face with tears').isNotEmpty, true);
      expect(searchEmojis(' '), isEmpty);
    });
  });

  group('translation', () {
    ChatMessage tr(
        {String? source = 'fr',
        Map<String, String>? t,
        String text = 'Bonjour'}) {
      return _msg('1', text: text).copyWith(
        langSource: source,
        translations: t ?? const <String, String>{'en': 'Hello'},
      );
    }

    test('returns the attached translation for another language', () {
      final r = resolveMessageTranslation(tr(), 'en-CA');
      expect(r.needsTranslation, true);
      expect(r.hasTranslation, true);
      expect(r.displayText, 'Hello');
    });

    test('same base language needs nothing', () {
      final r = resolveMessageTranslation(tr(source: 'en-US'), 'en-CA');
      expect(r.needsTranslation, false);
      expect(r.displayText, 'Bonjour');
    });

    test('identical translation and letterless text are ignored', () {
      expect(
        resolveMessageTranslation(tr(t: const {'en': 'Bonjour'}), 'en')
            .hasTranslation,
        false,
      );
      expect(resolveMessageTranslation(tr(text: '42'), 'en').needsTranslation,
          false);
      expect(resolveMessageTranslation(tr(source: null), 'en').needsTranslation,
          false);
    });
  });

  group('receipts policy', () {
    const cfg = ReceiptsConfig();
    test('private rooms always ack, big rooms do not', () {
      final m = _msg('1', at: DateTime.now().millisecondsSinceEpoch);
      const priv = ChatRoom(jid: _room, type: 'private');
      const small = ChatRoom(jid: _room, usersCnt: 10);
      const big = ChatRoom(jid: _room, usersCnt: 80);
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(
          shouldSendDelivery(room: priv, message: m, config: cfg, nowMs: now),
          true);
      expect(
          shouldSendDelivery(room: small, message: m, config: cfg, nowMs: now),
          true);
      expect(shouldSendDelivery(room: big, message: m, config: cfg, nowMs: now),
          false);
      expect(
        shouldSendDelivery(
          room: big,
          message: m,
          config: const ReceiptsConfig(mode: 'all'),
          nowMs: now,
        ),
        true,
      );
      expect(
        shouldSendDelivery(
          room: priv,
          message: m,
          config: const ReceiptsConfig(mode: 'off'),
          nowMs: now,
        ),
        false,
      );
    });

    test('old messages are not acked in auto mode', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final old = _msg('1', at: now - 9 * 24 * 3600 * 1000);
      expect(
        shouldSendDelivery(
          room: const ChatRoom(jid: _room, usersCnt: 5),
          message: old,
          config: const ReceiptsConfig(),
          nowMs: now,
        ),
        false,
      );
    });

    test('read marker limit', () {
      expect(
          shouldSendRead(
              room: const ChatRoom(jid: _room, usersCnt: 100),
              config: const ReceiptsConfig()),
          true);
      expect(
          shouldSendRead(
              room: const ChatRoom(jid: _room, usersCnt: 300),
              config: const ReceiptsConfig()),
          false);
    });
  });

  group('DeliveryReceiptBatcher', () {
    test('acks the first at once and the newest of a burst at window end', () {
      final sent = <String>[];
      final timers = <void Function()>[];
      final batcher = DeliveryReceiptBatcher(
        send: (room, id) => sent.add(id),
        timerFactory: (d, f) {
          timers.add(f);
          return _FakeTimer();
        },
      );
      batcher.enqueue(_room, 'a', 1500, timestamp: 1);
      batcher.enqueue(_room, 'b', 1500, timestamp: 2);
      batcher.enqueue(_room, 'c', 1500, timestamp: 3);
      expect(sent, ['a']);
      timers.removeAt(0)();
      expect(sent, ['a', 'c']);
      // a repeat of an acked id never goes out again
      batcher.enqueue(_room, 'c', 1500, timestamp: 4);
      expect(sent, ['a', 'c']);
    });
  });

  group('DisplayedMarkerThrottle', () {
    test('first mark immediately, held mark trails', () {
      var now = 10000;
      final sent = <String>[];
      final fired = <void Function()>[];
      final throttle = DisplayedMarkerThrottle(
        send: sent.add,
        now: () => now,
        timerFactory: (d, f) {
          fired.add(f);
          return _FakeTimer();
        },
      );
      throttle.mark('1');
      now += 500;
      throttle.mark('2');
      throttle.mark('3');
      expect(sent, ['1']);
      now += 3000;
      fired.removeAt(0)();
      expect(sent, ['1', '3']);
    });

    test('dispose flushes the held mark', () {
      var now = 10000;
      final sent = <String>[];
      final throttle = DisplayedMarkerThrottle(
        send: sent.add,
        now: () => now,
        timerFactory: (d, f) => _FakeTimer(),
      );
      throttle.mark('1');
      throttle.mark('2');
      throttle.dispose();
      expect(sent, ['1', '2']);
    });
  });

  group('tick state', () {
    test('seen when another watermark covers it, delivered via receivedBy', () {
      final list = [
        _msg('100', sender: 'me', at: 1),
        _msg('200', sender: 'me', at: 2),
        _msg('300', sender: 'bob', at: 3),
      ];
      const room = ChatRoom(
        jid: _room,
        lastDisplayedByUser: <String, String>{'bob': '200', 'me': '300'},
      );
      expect(
          computeReceiptState(messages: list, index: 0, room: room, me: 'me')
              .seen,
          true);
      expect(
          computeReceiptState(messages: list, index: 1, room: room, me: 'me')
              .seen,
          true);
      final plain = [
        _msg('100', sender: 'me').copyWith(receivedBy: const {'bob': 5}),
        _msg('200', sender: 'me'),
      ];
      const noMarks = ChatRoom(jid: _room);
      final first = computeReceiptState(
          messages: plain, index: 0, room: noMarks, me: 'me');
      expect(first.seen, false);
      expect(first.delivered, true);
      final second = computeReceiptState(
          messages: plain, index: 1, room: noMarks, me: 'me');
      expect(second.delivered, false);
    });
  });

  group('controller messaging', () {
    test('toggleReaction resends my full set', () async {
      final (controller, fake) = await _boot();
      fake.emitIncoming(_msg('1712000000000001'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await controller.toggleReaction(_room, '1712000000000001', 'heart');
      expect(fake.sentReactions.last.$3, ['heart']);

      fake.emitReaction(
        ParsedReaction(
          roomJid: _room,
          targetId: '1712000000000001',
          reactor: 'me',
          reaction:
              const ChatReaction(emoji: ['heart'], ts: '1712000000000999'),
        ),
      );
      await controller.toggleReaction(_room, '1712000000000001', 'joy');
      expect(fake.sentReactions.last.$3, ['heart', 'joy']);
      fake.emitReaction(
        ParsedReaction(
          roomJid: _room,
          targetId: '1712000000000001',
          reactor: 'me',
          reaction: const ChatReaction(
            emoji: ['heart', 'joy'],
            ts: '1712000000001000',
          ),
        ),
      );
      await controller.toggleReaction(_room, '1712000000000001', 'heart');
      expect(fake.sentReactions.last.$3, ['joy']);
      controller.dispose();
    });

    test('reaction before its message is parked then applied', () async {
      final (controller, fake) = await _boot();
      fake.emitReaction(
        ParsedReaction(
          roomJid: _room,
          targetId: '1712000000000050',
          reactor: 'bob',
          reaction: const ChatReaction(emoji: ['fire'], ts: '1712000000000900'),
        ),
      );
      fake.emitIncoming(_msg('1712000000000050', at: 5));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final stored = controller.messageById(_room, '1712000000000050')!;
      expect(stored.reactions['bob']!.emoji, ['fire']);
      controller.dispose();
    });

    test('an older reaction never overrides a newer one', () async {
      final (controller, fake) = await _boot();
      fake.emitIncoming(_msg('1712000000000001'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ParsedReaction at(String ts, List<String> emoji) => ParsedReaction(
            roomJid: _room,
            targetId: '1712000000000001',
            reactor: 'bob',
            reaction: ChatReaction(emoji: emoji, ts: ts),
          );
      fake.emitReaction(at('1712000000000500', const ['joy']));
      fake.emitReaction(at('1712000000000100', const ['heart']));
      expect(
        controller
            .messageById(_room, '1712000000000001')!
            .reactions['bob']!
            .emoji,
        ['joy'],
      );
      // an empty list is kept as a removal marker
      fake.emitReaction(at('1712000000000700', const []));
      expect(
        controller
            .messageById(_room, '1712000000000001')!
            .reactions['bob']!
            .emoji,
        isEmpty,
      );
      controller.dispose();
    });

    test('thread reply carries mainMessage and showInChannel', () async {
      final (controller, fake) = await _boot();
      fake.emitIncoming(_msg('1712000000000001', text: 'root', at: 1));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      controller.openThreadById(_room, '1712000000000001');
      await controller.sendThreadReply('answer', alsoSendToRoom: true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final sent = fake.sentTexts.last;
      expect(sent['isReply'], true);
      expect(sent['showInChannel'], true);
      final ref = parseMessageReference(sent['mainMessage']! as String)!;
      expect(ref.id, '1712000000000001');
      expect(ref.text, 'root');
      // thread-only reply is hidden from the channel and listed in the thread
      await controller.sendThreadReply('quiet');
      final list = controller.state.value.messagesByRoom[_room]!;
      final quiet = list.last;
      expect(quiet.isReply, true);
      expect(quiet.showInChannel, false);
      expect(controller.threadRepliesOf(_room, '1712000000000001').length, 2);
      controller.dispose();
    });

    test('edit and delete', () async {
      final (controller, fake) = await _boot();
      fake.emitIncoming(_msg('1712000000000001', sender: 'me', text: 'old'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final own = controller.messageById(_room, '1712000000000001')!;
      expect(controller.canEditMessage(own), true);
      controller.startEdit(own);
      expect(controller.state.value.editDraft!.text, 'old');
      await controller.submitEdit('new text');
      expect(fake.sentEdits.single, (_room, '1712000000000001', 'new text'));
      expect(
          controller.messageById(_room, '1712000000000001')!.text, 'new text');
      expect(controller.state.value.editDraft, isNull);

      await controller
          .deleteMessage(controller.messageById(_room, '1712000000000001')!);
      expect(fake.sentDeletes.single, (_room, '1712000000000001'));
      expect(
          controller.messageById(_room, '1712000000000001')!.isDeleted, true);

      final foreign = _msg('1712000000000002', sender: 'bob');
      expect(controller.canEditMessage(foreign), false);
      expect(controller.canDeleteMessage(foreign), false);
      controller.dispose();
    });

    test('incoming message from someone else triggers a delivery receipt',
        () async {
      final (controller, fake) = await _boot();
      fake.emitIncoming(
          _msg('1712000000000007', at: DateTime.now().millisecondsSinceEpoch));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(fake.sentReceipts, [(_room, '1712000000000007')]);
      // own echo and history replays are never acked
      fake.emitIncoming(_msg('1712000000000008', sender: 'me'));
      fake.emitIncoming(_msg('1712000000000009').copyWith(isHistory: true));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(fake.sentReceipts.length, 1);
      controller.dispose();
    });

    test('receipt and displayed marker update the state', () async {
      final (controller, fake) = await _boot();
      fake.emitIncoming(_msg('1712000000000001', sender: 'me'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      fake.emitReceipt(
        const ParsedReceipt(
          roomJid: _room,
          messageId: '1712000000000001',
          fromXmppUsername: 'bob',
        ),
      );
      expect(
        controller.messageById(_room, '1712000000000001')!.receivedBy.keys,
        ['bob'],
      );
      fake.emitDisplayed(
        const ParsedDisplayed(
          roomJid: _room,
          messageId: '1712000000000001',
          xmppUsername: 'bob',
        ),
      );
      final room = controller.state.value.rooms.single;
      expect(room.lastDisplayedByUser['bob'], '1712000000000001');
      // own receipts are ignored
      fake.emitReceipt(
        const ParsedReceipt(
          roomJid: _room,
          messageId: '1712000000000001',
          fromXmppUsername: 'me',
        ),
      );
      expect(
        controller.messageById(_room, '1712000000000001')!.receivedBy.length,
        1,
      );
      controller.dispose();
    });
  });
}

class _FakeTimer implements Timer {
  @override
  void cancel() {}

  @override
  bool get isActive => true;

  @override
  int get tick => 0;
}
