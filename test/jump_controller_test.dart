import 'dart:convert';

import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rooms_support.dart';

const _room = 'room@conference.xmpp.test';
const _other = 'other@conference.xmpp.test';

RoomsHarness _harness(FakeArchive archive, {FakeArchive? second}) {
  final h = RoomsHarness(
    rooms: const [
      ChatRoom(jid: _room, title: 'Room'),
      ChatRoom(jid: _other, title: 'Other'),
    ],
  );
  h.xmpp.archives[_room] = archive;
  if (second != null) h.xmpp.archives[_other] = second;
  return h;
}

FakeArchive _archive(int count, {String room = _room}) => FakeArchive(
      room,
      [for (var i = 1; i <= count; i++) archiveMessage(room, i)],
    );

void main() {
  test('near target: scrolls the live list, no window', () async {
    final archive = _archive(100);
    final h = _harness(archive);
    await h.start();
    final live = h.controller.state.value.messagesByRoom[_room]!;
    expect(live.length, 30);

    final target = live[5];
    final outcome = await h.controller.jumpToMessage(
      roomJid: _room,
      ids: [target.id],
    );
    expect(outcome, JumpOutcome.reached);
    final state = h.controller.state.value;
    expect(state.jumpTarget?.messageId, target.id);
    expect(state.jumpTarget?.roomJid, _room);
    expect(state.jumpWindowByRoom, isEmpty);
    expect(archive.calls.where((c) => c['deliver'] == false), isEmpty);
    h.dispose();
  });

  test('far target: a window of 10 before and 10 after replaces the live list',
      () async {
    final archive = _archive(200);
    final h = _harness(archive);
    await h.start();
    final target = archive.rows[40];

    final outcome = await h.controller.jumpToMessage(
      roomJid: _room,
      ids: [target.id],
    );
    expect(outcome, JumpOutcome.reached);
    final state = h.controller.state.value;
    final window = state.jumpWindowByRoom[_room]!;
    expect(window.length, 21);
    expect(window.first.id, archive.rows[30].id);
    expect(window.last.id, archive.rows[50].id);
    expect(state.jumpTarget?.messageId, target.id);
    expect(state.jumpTarget?.threadRootId, isNull);
    // the live list is untouched
    expect(state.messagesByRoom[_room]!.length, 30);
    expect(h.controller.jumpWindowHasOlder(_room), true);
    expect(h.controller.jumpWindowHasNewer(_room), true);

    h.controller.clearJumpWindow(_room);
    expect(h.controller.state.value.jumpWindowByRoom, isEmpty);
    expect(h.controller.state.value.jumpTarget, isNull);
    h.dispose();
  });

  test('a target in a live list farther than 300 uses a window too', () async {
    final archive = _archive(400);
    final h = _harness(archive);
    await h.start();
    // load the whole archive into the live list
    for (final m in archive.rows) {
      h.xmpp.onMessage?.call(m);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.controller.state.value.messagesByRoom[_room]!.length, 400);

    final far = archive.rows[10];
    await h.controller.jumpToMessage(roomJid: _room, ids: [far.id]);
    final window = h.controller.state.value.jumpWindowByRoom[_room];
    expect(window, isNotNull);
    expect(window!.any((m) => m.id == far.id), true);
    h.dispose();
  });

  test('opens the room of the hit first', () async {
    final archive = _archive(200);
    final h = _harness(archive, second: _archive(200, room: _other));
    await h.start();
    expect(h.controller.state.value.selectedRoomJid, _room);

    final target = h.xmpp.archives[_other]!.rows[3];
    final outcome =
        await h.controller.jumpToMessage(roomJid: _other, ids: [target.id]);
    expect(outcome, JumpOutcome.reached);
    expect(h.controller.state.value.selectedRoomJid, _other);
    expect(h.controller.state.value.jumpTarget?.roomJid, _other);
    h.dispose();
  });

  test('a hit with no archive id is located by time and text', () async {
    final archive = _archive(200);
    final h = _harness(archive);
    await h.start();
    final wanted = archive.rows[60];

    final outcome = await h.controller.jumpToMessage(
      roomJid: _room,
      ids: const [],
      createdAt: wanted.createdAtMs + 900,
      body: wanted.text,
    );
    expect(outcome, JumpOutcome.reached);
    expect(h.controller.state.value.jumpTarget?.messageId, wanted.id);
    expect(h.controller.state.value.jumpWindowByRoom[_room], isNotEmpty);
    h.dispose();
  });

  test('a target the archive does not have is not found', () async {
    final archive = _archive(200);
    final h = _harness(archive);
    await h.start();
    final outcome = await h.controller
        .jumpToMessage(roomJid: _room, ids: ['${archiveId(5000)}']);
    expect(outcome, JumpOutcome.notFound);
    expect(h.controller.state.value.jumpTarget, isNull);
    expect(h.controller.state.value.jumpWindowByRoom, isEmpty);
    h.dispose();
  });

  test('empty request is not found without touching the archive', () async {
    final archive = _archive(10);
    final h = _harness(archive);
    await h.start();
    final before = archive.calls.length;
    expect(
      await h.controller.jumpToMessage(roomJid: _room, ids: const ['  ']),
      JumpOutcome.notFound,
    );
    expect(archive.calls.length, before);
    h.dispose();
  });

  test('window not available: pages older history into the live list',
      () async {
    final archive = _archive(260)..failWindows = true;
    final h = _harness(archive);
    await h.start();
    final target = archive.rows[20];

    final outcome =
        await h.controller.jumpToMessage(roomJid: _room, ids: [target.id]);
    expect(outcome, JumpOutcome.reached);
    final state = h.controller.state.value;
    expect(state.jumpWindowByRoom, isEmpty);
    expect(state.jumpTarget?.messageId, target.id);
    expect(state.messagesByRoom[_room]!.any((m) => m.id == target.id), true);
    // pages of 100, each older than the last
    final pages = archive.calls
        .where((c) => c['deliver'] == true && c['max'] == 100)
        .toList();
    expect(pages, isNotEmpty);
    expect(pages.first['before'], isNotNull);
    h.dispose();
  });

  test('thread-only reply: names its root, and fetches the root when far',
      () async {
    final rows = <ChatMessage>[
      for (var i = 1; i <= 300; i++) archiveMessage(_room, i),
    ];
    final root = rows[5];
    final reply = archiveMessage(
      _room,
      301,
      text: 'a reply',
      isReply: true,
      mainMessage: jsonEncode({'id': root.id, 'text': root.text}),
    );
    final archive = FakeArchive(_room, [...rows, reply]);
    final h = _harness(archive);
    await h.start();

    final outcome =
        await h.controller.jumpToMessage(roomJid: _room, ids: [reply.id]);
    expect(outcome, JumpOutcome.reached);
    final state = h.controller.state.value;
    expect(state.jumpTarget?.messageId, reply.id);
    expect(state.jumpTarget?.threadRootId, root.id);
    expect(state.jumpTarget?.replyParentId, root.id);
    // the root is far from the live tail, so it was fetched into the window
    final window = state.jumpWindowByRoom[_room]!;
    expect(window.any((m) => m.id == root.id), true);
    expect(window.any((m) => m.id == reply.id), true);
    h.dispose();
  });

  test('thread reply whose root is already live needs no extra fetch',
      () async {
    final rows = <ChatMessage>[
      for (var i = 1; i <= 20; i++) archiveMessage(_room, i),
    ];
    final root = rows[2];
    final reply = archiveMessage(
      _room,
      21,
      isReply: true,
      mainMessage: jsonEncode({'id': root.id}),
    );
    final archive = FakeArchive(_room, [...rows, reply]);
    final h = _harness(archive);
    await h.start();
    await h.controller.jumpToMessage(roomJid: _room, ids: [reply.id]);
    final state = h.controller.state.value;
    expect(state.jumpTarget?.threadRootId, root.id);
    expect(state.jumpWindowByRoom, isEmpty);
    expect(archive.calls.where((c) => c['deliver'] == false), isEmpty);
    h.dispose();
  });

  test('a newer jump supersedes the first', () async {
    final archive = _archive(200, room: _room);
    final h = _harness(archive);
    await h.start();
    final first =
        h.controller.jumpToMessage(roomJid: _room, ids: [archive.rows[40].id]);
    final second =
        h.controller.jumpToMessage(roomJid: _room, ids: [archive.rows[100].id]);
    expect(await first, JumpOutcome.superseded);
    expect(await second, JumpOutcome.reached);
    expect(
        h.controller.state.value.jumpTarget?.messageId, archive.rows[100].id);
    h.dispose();
  });

  test('a target already inside the window on screen does not refetch',
      () async {
    final archive = _archive(200);
    final h = _harness(archive);
    await h.start();
    await h.controller
        .jumpToMessage(roomJid: _room, ids: [archive.rows[40].id]);
    final calls = archive.calls.length;
    final nearby = archive.rows[44];
    final outcome =
        await h.controller.jumpToMessage(roomJid: _room, ids: [nearby.id]);
    expect(outcome, JumpOutcome.reached);
    expect(archive.calls.length, calls);
    expect(h.controller.state.value.jumpTarget?.messageId, nearby.id);
    h.dispose();
  });

  test('jump window pages older and newer', () async {
    final archive = _archive(300);
    final h = _harness(archive);
    await h.start();
    await h.controller
        .jumpToMessage(roomJid: _room, ids: [archive.rows[150].id]);
    final size = h.controller.state.value.jumpWindowByRoom[_room]!.length;
    expect(await h.controller.loadJumpWindowOlder(_room), true);
    expect(h.controller.state.value.jumpWindowByRoom[_room]!.length, size + 20);
    expect(await h.controller.loadJumpWindowNewer(_room), true);
    expect(h.controller.state.value.jumpWindowByRoom[_room]!.length, size + 40);
    h.dispose();
  });

  test('acknowledgeJumpTarget clears only the matching nonce', () async {
    final archive = _archive(20);
    final h = _harness(archive);
    await h.start();
    await h.controller
        .jumpToMessage(roomJid: _room, ids: [archive.rows[10].id]);
    final nonce = h.controller.state.value.jumpTarget!.nonce;
    h.controller.acknowledgeJumpTarget(nonce + 1);
    expect(h.controller.state.value.jumpTarget, isNotNull);
    h.controller.acknowledgeJumpTarget(nonce);
    expect(h.controller.state.value.jumpTarget, isNull);
    h.dispose();
  });

  group('older history paging uses the server cursor', () {
    test('a page of only non-message rows still moves paging back', () async {
      final archive = _archive(120);
      final h = _harness(archive);
      await h.start();
      // first older page
      expect(await h.controller.loadOlderMessages(_room), true);
      final firstBefore = archive.calls.last['before'];
      expect(firstBefore, archive.rows[90].id);
      expect(await h.controller.loadOlderMessages(_room), true);
      expect(int.parse(archive.calls.last['before']! as String),
          lessThan(int.parse(firstBefore! as String)));
      h.dispose();
    });

    test('a latest page marked complete marks the history complete', () async {
      final archive = _archive(5);
      final h = _harness(archive);
      await h.start();
      final room =
          h.controller.state.value.rooms.firstWhere((r) => r.jid == _room);
      expect(room.historyComplete, true);
      expect(await h.controller.loadOlderMessages(_room), false);
      h.dispose();
    });
  });
}
