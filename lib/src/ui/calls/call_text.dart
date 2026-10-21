import '../../i18n/chat_i18n.dart';

/// Caption for a call key: the SDK string table (and the host's i18n
/// overrides) when it has one, else the English [fallback]. Most call
/// captions are web hardcoded English, so only a few keys exist in the table.
String callText(
  ChatStrings strings,
  String key,
  String fallback, [
  Map<String, Object>? vars,
]) {
  final value = strings.t(key, vars);
  return value == key ? interpolate(fallback, vars) : value;
}

/// `mm:ss` (or `h:mm:ss`) for a call timer.
String formatCallClock(Duration elapsed) {
  final total = elapsed.inSeconds < 0 ? 0 : elapsed.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}
