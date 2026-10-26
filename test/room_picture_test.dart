import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rooms_support.dart';

const _a = 'app_a@conference.xmpp.test';

const _png = MediaFileInput(
  bytes: <int>[1, 2, 3],
  filename: 'logo.png',
  mimeType: 'image/png',
);

ApiHandler _api({bool patchFails = false, bool uploadEmpty = false}) => (r) {
      if (r.path == '/v2/files/secure') {
        return jsonResponse(uploadEmpty
            ? {'results': []}
            : {
                'results': [
                  {'_id': 'p1', 'location': 'https://files.test/logo.png'},
                ],
              });
      }
      if (r.method == 'PATCH') {
        return patchFails ? jsonResponse({}, 500) : jsonResponse({});
      }
      if (r.method == 'POST' && r.path == '/v1/chats') {
        return jsonResponse({
          'result': {'name': 'app_new', 'title': 'Team', 'type': 'group'},
        });
      }
      return null;
    };

Future<RoomsHarness> _started({ApiHandler? handler}) async {
  final h = RoomsHarness(
    rooms: const [ChatRoom(jid: _a, title: 'Alpha', role: 'moderator')],
    handler: handler,
  );
  await h.start();
  return h;
}

void main() {
  test('setRoomPicture: upload, PATCH the chat, XMPP room profile, state',
      () async {
    final h = await _started(handler: _api());
    final url = await h.controller.setRoomPicture(_a, _png);
    expect(url, 'https://files.test/logo.png');

    final upload = h.where('POST', '/v2/files/secure').single;
    expect('${upload.body}', contains('app_a')); // scoped to the chat
    final patch = h.where('PATCH', '/v1/chats/my/app_a').single;
    expect(patch.json, {'picture': 'https://files.test/logo.png'});
    expect(h.xmpp.images, [(_a, 'https://files.test/logo.png')]);
    expect(
      h.controller.state.value.rooms.single.picture,
      'https://files.test/logo.png',
    );
    h.dispose();
  });

  test('a failed PATCH is not fatal: the picture still shows this session',
      () async {
    final h = await _started(handler: _api(patchFails: true));
    await h.controller.setRoomPicture(_a, _png);
    expect(h.xmpp.images, hasLength(1));
    expect(h.controller.state.value.rooms.single.picture, isNotEmpty);
    h.dispose();
  });

  test('an upload without a location changes nothing', () async {
    final h = await _started(handler: _api(uploadEmpty: true));
    await expectLater(h.controller.setRoomPicture(_a, _png), throwsA(anything));
    expect(h.where('PATCH', 'chats'), isEmpty);
    expect(h.xmpp.images, isEmpty);
    expect(h.controller.state.value.rooms.single.picture, isNull);
    h.dispose();
  });

  test('removeRoomPicture clears it on the server, XMPP and locally', () async {
    final h = await _started(handler: _api());
    await h.controller.setRoomPicture(_a, _png);
    await h.controller.removeRoomPicture(_a);
    expect(h.where('PATCH', '/v1/chats/my/app_a').last.json, {'picture': ''});
    expect(h.xmpp.images.last, (_a, ''));
    expect(h.controller.state.value.rooms.single.picture, '');
    h.dispose();
  });

  test('creating a group with a picture uploads it once the room exists',
      () async {
    final h = await _started(handler: _api());
    final room = await h.controller.createGroupChat(
      title: 'Team',
      avatar: _png,
    );
    const jid = 'app_new@conference.xmpp.test';
    expect(room.jid, jid);
    expect(room.picture, 'https://files.test/logo.png');
    expect(h.where('PATCH', '/v1/chats/my/app_new'), hasLength(1));
    expect(h.xmpp.images, [(jid, 'https://files.test/logo.png')]);
    h.dispose();
  });

  test('a failed picture does not undo the room', () async {
    final h = await _started(
        handler: (r) => r.path == '/v2/files/secure' || r.path == '/files/'
            ? jsonResponse({}, 422)
            : _api()(r));
    final room =
        await h.controller.createGroupChat(title: 'Team', avatar: _png);
    expect(room.jid, 'app_new@conference.xmpp.test');
    expect(
      h.controller.state.value.rooms.any((r) => r.jid == room.jid),
      true,
    );
    h.dispose();
  });

  test('ApiClient.patch sends PATCH with a JSON body', () async {
    final h = RoomsHarness();
    await h.controller.roomActions.patchRoom(
      'app_a',
      title: 'T',
      description: '',
    );
    final call = h.requests.single;
    expect(call.method, 'PATCH');
    expect(call.json, {'title': 'T', 'description': ''});
    h.dispose();
  });

  test('the room image stanza is the web profile iq', () {
    final stanza = buildRoomImageStanza(
      roomJid: _a,
      thumbnail: 'https://x/a&b.png',
    );
    expect(stanza, contains('id="setRoomImage"'));
    expect(stanza, contains('xmlns="ns:getrooms:setprofile"'));
    expect(stanza, contains('room_thumbnail="https://x/a&amp;b.png"'));
    expect(stanza, contains('room_background="none"'));
    expect(stanza, contains('room="$_a"'));
  });
}
