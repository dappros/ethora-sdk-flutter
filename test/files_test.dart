import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rooms_support.dart';

ApiFile _file(
  String id, {
  String name = 'a.png',
  String mime = 'image/png',
  String room = '',
  String location = '',
  int? size,
}) =>
    ApiFile(
      id: id,
      location: location.isEmpty ? 'https://files.test/$id' : location,
      originalName: name,
      mimetype: mime,
      roomName: room,
      size: size,
    );

/// A files service over an in-memory list.
class _FakeFiles extends FilesService {
  _FakeFiles(this.all)
      : super(
          apiClient: ApiClient(
            config: const ChatComponentConfig(),
            readAccessToken: () async => null,
            readRefreshToken: () async => null,
            writeTokens: (_, __) async {},
            clearSession: () async {},
            log: (_) {},
          ),
        );

  final List<ApiFile> all;
  final List<int> offsets = <int>[];
  Object? failList;
  Object? failDelete;
  int total = -1;

  @override
  Future<FilesPage> list({int limit = kFilesPageSize, int offset = 0}) async {
    offsets.add(offset);
    if (failList != null) throw failList!;
    support = FilesEndpointSupport.supported;
    final slice = all.skip(offset).take(limit).toList();
    return FilesPage(
      items: slice,
      total: total >= 0 ? total : all.length,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<void> delete(String id) async {
    if (failDelete != null) throw failDelete!;
    all.removeWhere((f) => f.id == id);
  }
}

void main() {
  group('parse and helpers', () {
    test('parseFilesPage reads items or results and the pagination block', () {
      final a = parseFilesPage(
        {
          'items': [
            {
              '_id': 'f1',
              'location': 'https://x/f1',
              'originalname': 'cat.png',
              'mimetype': 'image/png',
              'size': 1536,
              'roomName': 'app_a@conference.x',
              'createdAt': '2026-07-14T10:00:00Z',
            },
          ],
          'pagination': {'total': 12, 'limit': 5, 'offset': 10},
        },
        limit: 50,
        offset: 0,
      );
      expect(a.items.single.id, 'f1');
      expect(a.items.single.displayName, 'cat.png');
      expect(a.items.single.size, 1536);
      expect(a.total, 12);
      expect(a.limit, 5);
      expect(a.offset, 10);

      final b = parseFilesPage(
        {
          'results': [
            {'_id': 'f2', 'location': 'https://x/dir/doc.pdf'},
          ],
        },
        limit: 50,
        offset: 0,
      );
      expect(b.items.single.displayName, 'doc.pdf'); // from the URL
      expect(b.total, 1);
      expect(parseFilesPage({'items': 'nope'}, limit: 1, offset: 0).items,
          isEmpty);
    });

    test('a file belongs to a chat by name or by JID', () {
      expect(_file('1', room: 'app_a').belongsToRoom('app_a'), true);
      expect(
          _file('1', room: 'app_a@conference.x').belongsToRoom('app_a'), true);
      expect(_file('1', room: 'app_b').belongsToRoom('app_a'), false);
      expect(_file('1').belongsToRoom('app_a'), false);
      expect(_file('1', room: 'app_a').belongsToRoom(''), false);
    });

    test('categories follow the mimetype; svg is a document', () {
      expect(fileCategoryOf('image/png'), FileCategory.media);
      expect(fileCategoryOf('video/mp4'), FileCategory.media);
      expect(fileCategoryOf('audio/ogg'), FileCategory.audio);
      expect(fileCategoryOf('application/pdf'), FileCategory.documents);
      expect(fileCategoryOf('image/svg+xml'), FileCategory.documents);
      expect(fileCategoryOf('image/png', 'x.svg'), FileCategory.documents);
      expect(fileCategoryOf(null), FileCategory.documents);
    });

    test('pictures, videos and pdfs preview; svg and the rest do not', () {
      expect(isFilePreviewable('image/jpeg'), true);
      expect(isFilePreviewable('video/mp4'), true);
      expect(isFilePreviewable('application/pdf'), true);
      expect(isFilePreviewable('image/svg+xml'), false);
      expect(isFilePreviewable('application/zip'), false);
      expect(isFilePreviewable(null), false);
    });

    test('formatBytes', () {
      expect(formatBytes(null), '0 B');
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytes(1 << 62), contains('TB'));
    });

    test('filterFiles by category and name fragment', () {
      final files = [
        _file('1', name: 'Holiday.PNG'),
        _file('2', name: 'report.pdf', mime: 'application/pdf'),
        _file('3', name: 'song.mp3', mime: 'audio/mpeg'),
      ];
      expect(filterFiles(files).length, 3);
      expect(filterFiles(files, category: FileCategory.media).single.id, '1');
      expect(filterFiles(files, category: FileCategory.audio).single.id, '3');
      expect(filterFiles(files, query: ' REPORT ').single.id, '2');
      expect(
        filterFiles(files, category: FileCategory.media, query: 'report'),
        isEmpty,
      );
    });

    test('findMessagesForFile: by attachment id or location, not deleted ones',
        () {
      ChatMessage msg(String id,
              {Map<String, String>? data,
              List<Map<String, String>>? atts,
              String? url,
              bool deleted = false}) =>
          ChatMessage(
            id: id,
            roomJid: 'r@c',
            text: 'media',
            user: const ChatUser(),
            createdAtMs: 1,
            mediaUrl: url,
            data: data ?? const {},
            attachments: atts ?? const [],
            isDeleted: deleted,
          );
      final file = _file('f1', location: 'https://files.test/f1');
      final found = findMessagesForFile({
        'r@c': [
          msg('1', data: {'attachmentId': 'f1'}),
          msg('2', url: 'https://files.test/f1'),
          msg('3', atts: [
            {'attachmentId': 'zzz', 'location': 'https://other'},
            {'attachmentId': 'f1'},
          ]),
          msg('4', data: {'attachmentId': 'other'}),
          msg('5', data: {'attachmentId': 'f1'}, deleted: true),
          msg('6'),
        ],
        'q@c': [
          msg('7', data: {'attachmentId': 'f1'})
        ],
      }, file);
      expect(found.map((m) => '${m.roomJid}/${m.messageId}'),
          ['r@c/1', 'r@c/2', 'r@c/3', 'q@c/7']);
    });
  });

  group('FilesService', () {
    test('lists with limit and offset on /v2/files and marks support',
        () async {
      final h = RoomsHarness(
          handler: (r) => r.path == '/v2/files'
              ? jsonResponse({
                  'items': [
                    {'_id': 'f1', 'location': 'https://x/f1'},
                  ],
                  'pagination': {'total': 1},
                })
              : null);
      final service =
          FilesService(apiClient: h.controller.roomActions.apiClient);
      expect(service.support, FilesEndpointSupport.unknown);
      final page = await service.list(limit: 20, offset: 40);
      expect(h.requests.single.url.queryParameters,
          {'limit': '20', 'offset': '40'});
      expect(page.items.single.id, 'f1');
      expect(service.support, FilesEndpointSupport.supported);
      h.dispose();
    });

    test('404 and 501 mean this backend has no files route', () async {
      for (final code in [404, 501]) {
        final h = RoomsHarness(handler: (_) => jsonResponse({}, code));
        final service =
            FilesService(apiClient: h.controller.roomActions.apiClient);
        await expectLater(service.list(), throwsA(isA<ApiException>()));
        expect(service.support, FilesEndpointSupport.unsupported);
        h.dispose();
      }
      final h = RoomsHarness(handler: (_) => jsonResponse({}, 500));
      final service =
          FilesService(apiClient: h.controller.roomActions.apiClient);
      await expectLater(service.list(), throwsA(isA<ApiException>()));
      expect(service.support, FilesEndpointSupport.unknown);
      h.dispose();
    });

    test('delete is DELETE /v2/files/{id}', () async {
      final h = RoomsHarness();
      final service =
          FilesService(apiClient: h.controller.roomActions.apiClient);
      await service.delete('f 1');
      expect(h.requests.single.method, 'DELETE');
      expect(h.requests.single.path, '/v2/files/f%201');
      h.dispose();
    });
  });

  group('MyFilesModel', () {
    test('loads the first page once and pages on demand', () async {
      final fake = _FakeFiles([for (var i = 0; i < 7; i++) _file('f$i')]);
      final model = MyFilesModel(service: fake, pageSize: 3);
      await model.ensureLoaded();
      await model.ensureLoaded();
      expect(fake.offsets, [0]);
      expect(model.items.length, 3);
      expect(model.total, 7);
      expect(model.hasMore, true);

      await model.loadMore();
      await model.loadMore();
      expect(fake.offsets, [0, 3, 6]);
      expect(model.items.length, 7);
      expect(model.hasMore, false);
      await model.loadMore();
      expect(fake.offsets.length, 3);
      model.dispose();
    });

    test('a page with nothing new ends paging whatever total says', () async {
      final fake = _FakeFiles([_file('a'), _file('b')])..total = 99;
      final model = MyFilesModel(service: fake, pageSize: 2);
      await model.refresh();
      expect(model.hasMore, true);
      await model.loadMore(); // empty page
      expect(model.hasMore, false);
      model.dispose();
    });

    test('an error is kept, and refresh recovers', () async {
      final fake = _FakeFiles([_file('a')])..failList = StateError('boom');
      final model = MyFilesModel(service: fake);
      await model.ensureLoaded();
      expect(model.error, isNotNull);
      expect(model.items, isEmpty);
      expect(model.loading, false);
      fake.failList = null;
      await model.refresh();
      expect(model.error, isNull);
      expect(model.items.length, 1);
      model.dispose();
    });

    test('remove leaves at once and comes back when the request fails',
        () async {
      final fake = _FakeFiles([_file('a'), _file('b')]);
      final model = MyFilesModel(service: fake);
      await model.refresh();
      await model.remove('a');
      expect(model.items.map((f) => f.id), ['b']);
      expect(model.total, 1);

      fake.failDelete = StateError('no');
      await expectLater(model.remove('b'), throwsA(isA<StateError>()));
      expect(model.items.map((f) => f.id), ['b']);
      expect(model.total, 1);
      expect(model.error, isNotNull);
      model.dispose();
    });

    test('forRoom picks the files of one chat', () async {
      final fake = _FakeFiles([
        _file('a', room: 'app_a'),
        _file('b', room: 'app_b@conference.x'),
        _file('c'),
      ]);
      final model = MyFilesModel(service: fake);
      await model.refresh();
      expect(model.forRoom('app_b').map((f) => f.id), ['b']);
      expect(model.forRoom('app_a').map((f) => f.id), ['a']);
      model.dispose();
    });

    test('a stale answer never overwrites a newer refresh', () async {
      final fake = _FakeFiles([_file('a')]);
      final model = MyFilesModel(service: fake);
      final first = model.refresh();
      fake.all
        ..clear()
        ..add(_file('z'));
      await model.refresh();
      await first;
      expect(model.items.map((f) => f.id), ['z']);
      model.dispose();
    });
  });

  group('controller', () {
    const room = 'app_a@conference.xmpp.test';

    RoomsHarness seeded({ApiHandler? handler}) {
      final h = RoomsHarness(handler: handler);
      h.controller.state.value = ChatComponentState(
        isInitialized: true,
        user: kMe,
        rooms: const [
          ChatRoom(jid: room, title: 'Alpha', role: 'moderator', type: 'group'),
        ],
        messagesByRoom: {
          room: [
            ChatMessage(
              id: '${archiveId(1)}',
              roomJid: room,
              text: 'media',
              user: kMe,
              createdAtMs: 1,
              isMedia: true,
              mediaUrl: 'https://files.test/f1',
              data: const {'attachmentId': 'f1'},
            ),
            ChatMessage(
              id: '${archiveId(2)}',
              roomJid: room,
              text: 'hello',
              user: kMe,
              createdAtMs: 2,
            ),
          ],
        },
        selectedRoomJid: room,
      );
      return h;
    }

    test('deleting a file retracts the chat message that carries it', () async {
      final h = seeded();
      await h.controller.deleteMyFile(
        _file('f1', location: 'https://files.test/f1'),
      );
      expect(h.where('DELETE', '/v2/files/f1'), hasLength(1));
      final list = h.controller.state.value.messagesByRoom[room]!;
      expect(list[0].isDeleted, true);
      expect(list[1].isDeleted, false);
      h.dispose();
    });

    test('a failed file delete retracts nothing', () async {
      final h = seeded(
          handler: (r) => r.method == 'DELETE' ? jsonResponse({}, 500) : null);
      await expectLater(
        h.controller
            .deleteMyFile(_file('f1', location: 'https://files.test/f1')),
        throwsA(isA<ApiException>()),
      );
      expect(
          h.controller.state.value.messagesByRoom[room]![0].isDeleted, false);
      h.dispose();
    });

    test('myFiles is one shared model', () {
      final h = seeded();
      expect(identical(h.controller.myFiles, h.controller.myFiles), true);
      h.dispose();
    });
  });
}
