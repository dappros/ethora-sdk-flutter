import 'api_client.dart';

/// Account REST calls behind the settings screen (web/RN `user.api.ts`).
///
/// Failures surface as [ApiException]; [ApiException.reason] carries the
/// server's own message (for example why a password was refused).
class UserApi {
  UserApi(this._api);

  final ApiClient _api;

  /// `PUT /v1/users {appLanguage}`. One field per request, like web.
  Future<void> updateAppLanguage(String locale) async {
    await _api.put(
      '/v1/users',
      body: <String, dynamic>{'appLanguage': locale},
    );
  }

  /// `PUT /v1/users {chatLanguage}`.
  Future<void> updateChatLanguage(String locale) async {
    await _api.put(
      '/v1/users',
      body: <String, dynamic>{'chatLanguage': locale},
    );
  }

  /// `PUT /v2/users/me/password`.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _api.put(
      '/v2/users/me/password',
      body: <String, dynamic>{
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      },
    );
  }

  /// `DELETE /v1/users`: deletes the signed-in account.
  Future<void> deleteAccount() async {
    await _api.delete('/v1/users');
  }

  /// `GET /v1/users/exportData`: a copy of the account data (JSON bytes).
  Future<List<int>> exportData() => _api.getBytes('/v1/users/exportData');

  /// `POST /v1/users/xmpp-token` with body `{}`: a fresh SASL password for
  /// the signed-in user, or null when the server returns none.
  Future<String?> fetchXmppPassword({String? userToken}) async {
    final body = await _api.post(
      '/v1/users/xmpp-token',
      body: const <String, dynamic>{},
      headers: (userToken ?? '').isEmpty
          ? null
          : <String, String>{'Authorization': userToken!},
    );
    final password = body['xmppPassword']?.toString();
    return (password ?? '').isEmpty ? null : password;
  }
}
