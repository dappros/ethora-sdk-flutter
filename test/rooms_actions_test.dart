import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'rooms_support.dart';

void main() {
  late List<RecordedRequest> seen;
  late ApiHandler handler;
  late DateTime clock;
  late RoomActionsService service;

  RoomActionsService make() {
    seen = <RecordedRequest>[];
    clock = DateTime(2026, 1, 1);
    final h = RoomsHarness(handler: (r) {
      seen.add(r);
      return handler(r);
    });
    // The harness builds the controller; the service is built on its client.
    return RoomActionsService(
      apiClient: ApiClient(
        config: h.controller.config,
        readAccessToken: () async => 'token',
        readRefreshToken: () async => null,
        writeTokens: (_, __) async {},
        clearSession: () async {},
        log: (_) {},
        httpClient: h.mockClient,
      ),
      config: h.controller.config,
      now: () => clock,
    );
  }

  setUp(() {
    handler = (_) => jsonResponse(<String, dynamic>{});
  });

  test('mute is a PUT with an empty body, unmute a DELETE; result.muted wins',
      () async {
    service = make();
    handler = (r) => jsonResponse({
          'result': {'chatName': 'app_r', 'muted': r.method == 'PUT'},
        });
    expect(await service.setMuted('app_r', true), true);
    expect(await service.setMuted('app_r', false), false);
    expect(seen[0].method, 'PUT');
    expect(seen[0].path, '/v1/chats/my/app_r/mute');
    expect(seen[0].json, isEmpty);
    expect(seen[1].method, 'DELETE');
    expect(seen[1].path, '/v1/chats/my/app_r/mute');
  });

  test('mute falls back to the requested value when the answer omits it',
      () async {
    service = make();
    expect(await service.setMuted('app_r', true), true);
  });

  test('report bodies follow what the backend accepts', () {
    expect(buildReportBody('Spam', ''), {'category': 'spam', 'text': 'Spam'});
    expect(buildReportBody('Violence', 'hit me'),
        {'category': 'violance', 'text': 'hit me'});
    expect(buildReportBody('Personal Details', ' '),
        {'category': 'personal details', 'text': 'Personal Details'});
    expect(buildReportBody('Illegal Drugs', 'x'),
        {'category': 'illegal drugs', 'text': 'x'});
    expect(buildReportBody('Pornography', ''),
        {'category': 'pornography', 'text': 'Pornography'});
    expect(
        buildReportBody('Other', 'why'), {'category': 'other', 'text': 'why'});
    expect(buildReportBody('Child Abuse', ''),
        {'category': 'other', 'text': 'Child Abuse'});
    expect(buildReportBody('Child Abuse', 'details'),
        {'category': 'other', 'text': 'Child Abuse: details'});
    expect(buildReportBody('', ''), {'category': 'other', 'text': 'Other'});
  });

  test('report posts category and text', () async {
    service = make();
    await service.reportRoom('app_r', category: 'spam', text: 'junk');
    expect(seen.single.method, 'POST');
    expect(seen.single.path, '/v1/chats/reports/app_r');
    expect(seen.single.json, {'category': 'spam', 'text': 'junk'});
  });

  group('leave', () {
    test('DELETE users-access with the chat and me', () async {
      service = make();
      await service.leaveRoom('app_r', 'app_me');
      expect(seen.single.method, 'DELETE');
      expect(seen.single.path, '/v1/chats/users-access');
      expect(seen.single.json, {
        'chatName': 'app_r',
        'members': ['app_me'],
      });
    });

    test('a 404 counts as success', () async {
      service = make();
      handler = (_) => jsonResponse({'message': 'not found'}, 404);
      await service.leaveRoom('app_r', 'app_me');
    });

    test('any other failure is rethrown', () async {
      service = make();
      handler = (_) => jsonResponse({'message': 'boom'}, 500);
      await expectLater(
        service.leaveRoom('app_r', 'app_me'),
        throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'statusCode', 500)),
      );
      handler = (_) => jsonResponse({'message': 'no'}, 403);
      await expectLater(
        service.leaveRoom('app_r', 'app_me'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  test('add and remove members use users-access', () async {
    service = make();
    handler = (_) => jsonResponse({
          'results': [
            {'xmppUsername': 'app_x'},
          ],
        });
    final results = await service.addMembers('app_r', ['app_x', 'app_y']);
    expect(results, hasLength(1));
    expect(seen[0].method, 'POST');
    expect(seen[0].path, '/v1/chats/users-access');
    expect(seen[0].json, {
      'chatName': 'app_r',
      'members': ['app_x', 'app_y'],
    });
    await service.removeMembers('app_r', ['app_x']);
    expect(seen[1].method, 'DELETE');
    expect(seen[1].json, {
      'chatName': 'app_r',
      'members': ['app_x'],
    });
  });

  test('delete room sends the name', () async {
    service = make();
    await service.deleteRoom('app_r');
    expect(seen.single.method, 'DELETE');
    expect(seen.single.path, '/v1/chats');
    expect(seen.single.json, {'name': 'app_r'});
  });

  group('create', () {
    test('private chat omits e2ee unless true', () async {
      service = make();
      handler = (_) => jsonResponse({
            'result': {'name': 'app_p'},
          });
      await service.createPrivateRoom('app_bob');
      await service.createPrivateRoom('app_bob', e2ee: true);
      expect(seen[0].path, '/v1/chats/private');
      expect(seen[0].json, {'username': 'app_bob'});
      expect(seen[1].json, {'username': 'app_bob', 'e2ee': true});
    });

    test('group chat sends the whole payload', () async {
      service = make();
      handler = (_) => jsonResponse({
            'result': {'name': 'app_g'},
          });
      final result = await service.createRoom(
        title: 'Team',
        description: 'd',
        type: 'public',
        members: ['app_a'],
      );
      expect(result['name'], 'app_g');
      expect(seen.single.path, '/v1/chats');
      expect(seen.single.json, {
        'title': 'Team',
        'description': 'd',
        'picture': '',
        'type': 'public',
        'members': ['app_a'],
      });
    });

    test('an answer without a result is an error', () async {
      service = make();
      await expectLater(
        service.createPrivateRoom('x'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('public directory', () {
    test('asks with a capped limit and hides reported chats', () async {
      service = make();
      handler = (_) => jsonResponse({
            'items': [
              {'name': 'app_a', 'title': ' A ', 'e2ee': true},
              {'name': 'app_b', 'reported': true},
              {'name': '', 'title': 'no name'},
              {'name': 'app_c', 'description': 'desc'},
            ],
            'total': 130,
            'offset': 50,
            'limit': 50,
          });
      final page = await service.publicChats(offset: 50, limit: 500);
      expect(seen.single.url.queryParameters, {'limit': '50', 'offset': '50'});
      expect(page.items.map((c) => c.name), ['app_a', 'app_c']);
      expect(page.items.first.title, 'A');
      expect(page.items.first.e2ee, true);
      expect(page.nextOffset, 54);
      expect(page.hasMore, true);
      expect(page.items.last.displayTitle, 'app_c');
    });
  });

  group('user lookup', () {
    Map<String, dynamic> user() => {
          'result': {
            '_id': 'id1',
            'xmppUsername': 'app_u',
            'firstName': 'Ann',
            'lastName': 'Lee',
            'profileImage': 'p.png',
            'email': 'secret@mail',
          },
        };

    test('v1 answers: display fields only', () async {
      service = make();
      handler = (_) => jsonResponse(user());
      final result = await service.lookupUser('app_u');
      expect(result.status, UserLookupStatus.ok);
      expect(result.user!.displayName, 'Ann Lee');
      expect(result.user!.profileImage, 'p.png');
      expect(seen.single.path, '/v1/apps/users/app_u');
    });

    test('a refused v1 route falls back to v2 and is remembered', () async {
      service = make();
      handler = (r) => r.path.startsWith('/v1/')
          ? jsonResponse({'message': 'Invalid token type'}, 400)
          : jsonResponse(user());
      final first = await service.lookupUser('app_u');
      expect(first.status, UserLookupStatus.ok);
      expect(
          seen.map((r) => r.path), ['/v1/apps/users/app_u', '/v2/chats/users']);
      expect(seen.last.url.queryParameters, {'xmppUsername': 'app_u'});
      expect(service.isUserV1RouteUnsupported, true);

      seen.clear();
      await service.lookupUser('app_u');
      expect(seen.map((r) => r.path), ['/v2/chats/users']);

      // after the TTL v1 is probed again
      clock = clock.add(kUserRouteTtl + const Duration(seconds: 1));
      expect(service.isUserV1RouteUnsupported, false);
      seen.clear();
      await service.lookupUser('app_u');
      expect(seen.first.path, '/v1/apps/users/app_u');
    });

    test('a 401 and a bare 404 also fall back', () async {
      service = make();
      handler = (r) => r.path.startsWith('/v1/')
          ? jsonResponse({'message': 'Cannot GET'}, 404)
          : jsonResponse(user());
      expect((await service.lookupUser('app_u')).status, UserLookupStatus.ok);
      expect(seen, hasLength(2));
    });

    test('a 401 on v1 falls back to v2 without rotating tokens', () async {
      final paths = <String>[];
      var cleared = false;
      final client = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/v1/apps/users/app_u') {
          return http.Response('{"message":"Unauthorized"}', 401);
        }
        if (request.url.path.contains('login/refresh')) {
          return http.Response('{"token":"new","refreshToken":"r2"}', 200);
        }
        return jsonResponse(user());
      });
      const cfg = ChatComponentConfig(baseUrl: 'https://api.test');
      final api = ApiClient(
        config: cfg,
        readAccessToken: () async => 'aaa',
        readRefreshToken: () async => 'rrr',
        writeTokens: (_, __) async {},
        clearSession: () async => cleared = true,
        log: (_) {},
        httpClient: client,
      );
      final svc = RoomActionsService(apiClient: api, config: cfg);
      final result = await svc.lookupUser('app_u');
      expect(result.status, UserLookupStatus.ok);
      expect(paths, ['GET /v1/apps/users/app_u', 'GET /v2/chats/users']);
      expect(cleared, false);
      expect(svc.isUserV1RouteUnsupported, true);
    });

    test('USER_NOT_FOUND on v1 is an answer, not a missing route', () async {
      service = make();
      handler = (_) => jsonResponse({'code': 'USER_NOT_FOUND'}, 404);
      final result = await service.lookupUser('app_u');
      expect(result.status, UserLookupStatus.notFound);
      expect(seen, hasLength(1));
      expect(service.isUserV1RouteUnsupported, false);
    });

    test('a 403 on v1 is per user: no fallback, route stays supported',
        () async {
      service = make();
      handler = (_) => jsonResponse({'message': 'no shared room'}, 403);
      final result = await service.lookupUser('app_u');
      expect(result.status, UserLookupStatus.forbidden);
      expect(seen, hasLength(1));
      expect(service.isUserV1RouteUnsupported, false);
    });

    test('a blank id never calls the API', () async {
      service = make();
      expect(
          (await service.lookupUser('  ')).status, UserLookupStatus.notFound);
      expect(seen, isEmpty);
    });

    test('pickUserProfile reads every envelope', () {
      expect(pickUserProfile({'xmppUsername': 'a'})!.xmppUsername, 'a');
      expect(
        pickUserProfile({
          'item': [
            {'xmppUsername': 'b'},
          ],
        })!
            .xmppUsername,
        'b',
      );
      expect(pickUserProfile({'result': {}}), isNull);
      expect(pickUserProfile({}), isNull);
    });
  });

  test('chatRoomFromApi builds the JID from the chat name', () {
    final room = chatRoomFromApi(
      {'name': 'app_r', 'title': 'T', 'usersCnt': 3, 'type': 'group'},
      conference: 'conference.xmpp.test',
    );
    expect(room.jid, 'app_r@conference.xmpp.test');
    expect(room.title, 'T');
    expect(room.usersCnt, 3);
    final kept = chatRoomFromApi(
      {'jid': 'x@conference.other', 'name': 'x'},
      conference: 'conference.xmpp.test',
    );
    expect(kept.jid, 'x@conference.other');
  });
}
