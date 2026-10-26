import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../networking/api_client.dart';
import 'push_token_type.dart';

export 'push_token_type.dart';

/// `ios` on Apple platforms, `android` elsewhere (the backend knows no other
/// native value).
String resolvePushDeviceType() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return 'ios';
    default:
      return 'android';
  }
}

/// Registration failed in a way the host should know about: the backend
/// refused the payload ([status] and [body] carry its answer) or the request
/// never got there ([status] null).
class PushRegistrationError implements Exception {
  PushRegistrationError(this.message, {this.status, this.body});

  final String message;
  final int? status;
  final String? body;

  @override
  String toString() => 'PushRegistrationError($message)';
}

PushRegistrationError _toRegistrationError(Object error, String what) {
  if (error is ApiException) {
    final detail = error.reason ?? 'unknown error';
    return PushRegistrationError(
      '$what refused (HTTP ${error.statusCode}): $detail',
      status: error.statusCode,
      body: error.body,
    );
  }
  return PushRegistrationError('$what failed: $error');
}

bool _isUnknownFieldError(Object error) =>
    error is ApiException &&
    error.statusCode == 422 &&
    RegExp('not allowed', caseSensitive: false).hasMatch(error.body);

/// REST calls for push registration (RN `push.api.ts`).
class PushApi {
  PushApi({
    required ApiClient apiClient,
    http.Client? gatewayClient,
    String Function()? deviceType,
  })  : _api = apiClient,
        _gateway = gatewayClient ?? http.Client(),
        _deviceType = deviceType ?? resolvePushDeviceType;

  final ApiClient _api;
  final http.Client _gateway;
  final String Function() _deviceType;

  /// `POST /v1/push/subscription/{appId}`. A backend that predates
  /// `tokenType` still delivers to apns / fcm tokens, so a 422 "not allowed"
  /// is retried once without it.
  Future<void> register({
    required String appId,
    required String token,
    required PushTokenType tokenType,
  }) async {
    final path = '/v1/push/subscription/${Uri.encodeComponent(appId)}';
    final deviceType = _deviceType();
    try {
      await _api.post(
        path,
        body: <String, dynamic>{
          'registrationToken': token,
          'deviceType': deviceType,
          'tokenType': tokenType.wire,
        },
      );
      return;
    } catch (error) {
      final canDowngrade = tokenType != PushTokenType.apnsVoip;
      if (!(canDowngrade && _isUnknownFieldError(error))) {
        throw _toRegistrationError(error, 'Push registration');
      }
    }
    try {
      await _api.post(
        path,
        body: <String, dynamic>{
          'registrationToken': token,
          'deviceType': deviceType,
        },
      );
    } catch (error) {
      throw _toRegistrationError(error, 'Push registration');
    }
  }

  /// `DELETE /v1/push/subscription/{appId}`; on 404 falls back to
  /// `DELETE /v1/users/endpoints {endpoint}`.
  Future<void> unregister({
    required String appId,
    required String token,
  }) async {
    try {
      await _api.delete(
        '/v1/push/subscription/${Uri.encodeComponent(appId)}',
        body: <String, dynamic>{'registrationToken': token},
      );
      return;
    } catch (error) {
      if (!(error is ApiException && error.statusCode == 404)) {
        throw _toRegistrationError(error, 'Push unregistration');
      }
    }
    try {
      await _api.delete(
        '/v1/users/endpoints',
        body: <String, dynamic>{'endpoint': token},
      );
    } catch (error) {
      throw _toRegistrationError(error, 'Push unregistration');
    }
  }

  /// Gateway mode: `POST {apiUrl}/subscriptions` with `Bearer {userToken}`.
  /// [xmppUser] is the local part or a full JID; the XMPP [xmppHost] is
  /// appended to a bare local part.
  Future<void> subscribeToGateway({
    required String apiUrl,
    required String authToken,
    required String projectName,
    required String token,
    required String xmppUser,
    required String xmppHost,
  }) async {
    final base = apiUrl.trim().replaceAll(RegExp(r'/+$'), '');
    try {
      final response = await _gateway.post(
        Uri.parse('$base/subscriptions'),
        headers: <String, String>{
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $authToken',
        },
        body: jsonEncode(<String, dynamic>{
          'projectName': projectName,
          'registrationToken': token,
          'deviceType': _deviceType(),
          'jid': xmppUser.contains('@') ? xmppUser : '$xmppUser@$xmppHost',
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(response.statusCode, response.body);
      }
    } catch (error) {
      throw _toRegistrationError(error, 'Push gateway registration');
    }
  }
}
