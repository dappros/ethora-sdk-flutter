import '../core/chat_component_log.dart';
import 'api_client.dart';

/// Upload endpoints, like web auth.api uploadFile. The secure route is the
/// chat-scoped one (it needs `chatName`); the legacy route is the fallback
/// for backends that do not serve it yet. Paths are relative to the v1 base
/// (see ApiClient._uri), so the legacy one is `/files/`.
const String kSecureUploadEndpoint = '/v2/files/secure';
const String kLegacyUploadEndpoint = '/files/';

class MediaUploadService {
  MediaUploadService({
    required this.apiClient,
    required this.log,
  });

  final ApiClient apiClient;
  final void Function(ChatLogEvent event) log;

  /// Latched for the session once the secure route answers with a real
  /// rejection, so later uploads go straight to the legacy route.
  bool _secureUnavailable = false;

  /// Uploads one file to [roomJid] and returns its `results[0]` entry.
  Future<Map<String, dynamic>> uploadFile({
    required String roomJid,
    required List<int> bytes,
    required String filename,
    required String mimeType,
  }) async {
    if (!_secureUnavailable) {
      try {
        final body = await apiClient.upload(
          kSecureUploadEndpoint,
          bytes: bytes,
          filename: filename,
          mimeType: mimeType,
          fields: <String, String>{'chatName': roomJid.split('@').first},
        );
        return _firstResult(body);
      } catch (error) {
        if (!_canFallBack(error)) rethrow;
        _secureUnavailable = true;
        log(
          ChatLogEvent(
            level: ChatLogLevel.warn,
            category: ChatLogCategory.api,
            message:
                '$kSecureUploadEndpoint unavailable, falling back to $kLegacyUploadEndpoint for this session',
            timestamp: DateTime.now(),
          ),
        );
      }
    }
    final body = await apiClient.upload(
      kLegacyUploadEndpoint,
      bytes: bytes,
      filename: filename,
      mimeType: mimeType,
    );
    return _firstResult(body);
  }

  /// Web rethrows 401 (the refresh layer owns it) and 413 (an oversized file
  /// fails the same way on either route). Anything else falls back.
  bool _canFallBack(Object error) {
    if (error is! ApiException) return false;
    return error.statusCode != 401 && error.statusCode != 413;
  }

  Map<String, dynamic> _firstResult(Map<String, dynamic> body) {
    final nested = body['data'];
    final results = body['results'] ??
        (nested is Map<String, dynamic> ? nested['results'] : null);
    if (results is List && results.isNotEmpty && results.first is Map) {
      return Map<String, dynamic>.from(results.first as Map);
    }
    throw Exception('media_upload_empty_response');
  }
}
