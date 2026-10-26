// Which senders may steer a call's network targets (web calls/senderTrust.ts).
//
// A call-token can carry two attributes that decide WHERE media goes: the
// LiveKit `livekitUrl` and, for p2p, the `ice` list (TURN servers and their
// credentials). Honouring them from an arbitrary sender would let any user
// ring a victim with a forged call-token and route their camera and
// microphone to a server the sender controls once the call is accepted. The
// backend sends every genuine call-token from the app's system account, and
// ejabberd stamps the real JID on every message a client sends, so a normal
// user cannot appear as that account.
//
// The system account's local part is `<appId>_<appId>`: the 24 hex character
// app id, an underscore, the same 24 hex characters again.

final RegExp _systemAccountLocal = RegExp(r'^([0-9a-fA-F]{24})_\1$');

/// True when [fromJid] is the app's system account. The resource is ignored.
/// When [expectedDomain] is given the sender must also be on that XMPP domain,
/// so a same-looking account on a federated server is not accepted. A missing
/// or malformed JID is never trusted.
bool isSystemAccountSender(Object? fromJid, [String? expectedDomain]) {
  final from = fromJid is String ? fromJid.trim() : '';
  if (from.isEmpty) return false;
  final bare = from.split('/').first;
  final at = bare.indexOf('@');
  if (at <= 0 || bare.indexOf('@', at + 1) != -1) return false;
  final local = bare.substring(0, at);
  final domain = bare.substring(at + 1).toLowerCase();
  if (domain.isEmpty) return false;
  if (!_systemAccountLocal.hasMatch(local)) return false;
  final expected = (expectedDomain ?? '').trim().toLowerCase();
  return expected.isEmpty || domain == expected;
}
