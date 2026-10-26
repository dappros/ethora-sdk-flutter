/// Secure media helpers, like web helpers/secureFileUrl.ts.
///
/// Files uploaded through /v2/files/secure are served from a `secure-files.`
/// host and every download needs `?ft=<fileToken>` for the viewer's own
/// session. The token is appended at render time and must never be baked
/// into a URL that goes over XMPP.
const String _secureFilesHostPrefix = 'secure-files.';

bool isSecureFileUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final uri = Uri.tryParse(url);
  return uri != null && uri.host.startsWith(_secureFilesHostPrefix);
}

/// [url] with `ft=<fileToken>` set (replacing any earlier `ft`). Public
/// (non-secure) URLs and a missing token return [url] unchanged.
String appendFileToken(String? url, String? fileToken) {
  if (url == null || url.isEmpty) return '';
  if (fileToken == null || fileToken.isEmpty || !isSecureFileUrl(url)) {
    return url;
  }
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final params = Map<String, String>.from(uri.queryParameters)
    ..['ft'] = fileToken;
  return uri.replace(queryParameters: params).toString();
}
