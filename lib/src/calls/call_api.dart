// REST side of calls (web api-requests/rooms.api.ts createChatCall and
// callState.api.ts).
//
// A P2P call never touches LiveKit, so there is no LiveKit webhook to tell the
// server what happened: the clients report it. Every report is fire and
// forget (the UI never waits on it and a failure is only logged), and none of
// them may be sent for LiveKit calls (the server answers 409 CALL_NOT_P2P).

import 'dart:async';

import '../networking/api_client.dart';
import 'call_mode.dart';

/// `POST /v1/chats/call/create` failed (message is user facing).
class CallCreateException implements Exception {
  const CallCreateException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// How long the create request may take before the dial gives up.
const Duration kCallCreateTimeout = Duration(seconds: 15);

abstract class CallApi {
  /// `POST /v1/chats/call/create/{chatName}` with the call kind. [chatName] is
  /// the room JID localpart, never the display title.
  Future<CallCreateResult> createCall(String chatName, CallKind kind);

  /// Callee: the incoming UI is on screen.
  void reportRinging(String? callId);

  /// Callee: the user rejected the call. The server relays it to the caller.
  void reportDeclined(String? callId);

  /// Media is flowing (ICE connected). Starts the server-side call timer.
  void reportConnected(String? callId);

  /// A ringing or connected call ended for any reason. Idempotent on the
  /// server, so both peers may send it.
  void reportEnded(String? callId);

  /// `GET /v1/calls/ice-servers`: fresh STUN/TURN credentials, or null on any
  /// failure so callers can carry on with the servers they already have.
  Future<List<IceServerConfig>?> fetchIceServers();
}

class RestCallApi implements CallApi {
  RestCallApi(this._api, {void Function(String message, [Object? detail])? log})
      : _log = log;

  final ApiClient _api;
  final void Function(String message, [Object? detail])? _log;

  @override
  Future<CallCreateResult> createCall(String chatName, CallKind kind) async {
    try {
      final response = await _api.post(
        '/v1/chats/call/create/$chatName',
        body: <String, dynamic>{'kind': kind.name},
      ).timeout(kCallCreateTimeout);
      return parseCallCreateResponse(response, kind);
    } on TimeoutException {
      throw const CallCreateException('Call request timed out');
    } on ApiException catch (error) {
      throw CallCreateException(error.reason ?? 'Error creating chat call');
    } on FormatException {
      throw const CallCreateException('Error creating chat call');
    } catch (_) {
      throw const CallCreateException('Error creating chat call');
    }
  }

  void _report(String report, String? callId) {
    final id = (callId ?? '').trim();
    if (id.isEmpty) return;
    try {
      unawaited(
        _api
            .post('/v1/chats/call/state/$report/${Uri.encodeComponent(id)}')
            .then<void>((_) {})
            .catchError((Object error) {
          _log?.call('[call] state/$report report failed', error);
        }),
      );
    } catch (error) {
      _log?.call('[call] state/$report report failed', error);
    }
  }

  @override
  void reportRinging(String? callId) => _report('ringing', callId);

  @override
  void reportDeclined(String? callId) => _report('decline', callId);

  @override
  void reportConnected(String? callId) => _report('connected', callId);

  @override
  void reportEnded(String? callId) => _report('end', callId);

  @override
  Future<List<IceServerConfig>?> fetchIceServers() async {
    try {
      final data = await _api.get('/v1/calls/ice-servers');
      final servers = normalizeIceServers(data['iceServers']);
      // Older servers omit `enabled`; a non-empty list means usable.
      final enabled = data['enabled'] is bool
          ? data['enabled'] as bool
          : servers.isNotEmpty;
      return enabled && servers.isNotEmpty ? servers : null;
    } catch (error) {
      _log?.call('[call] ice-servers fetch failed', error);
      return null;
    }
  }
}
