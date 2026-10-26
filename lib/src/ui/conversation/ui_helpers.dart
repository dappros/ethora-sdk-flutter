import 'package:flutter/material.dart';

import '../../i18n/chat_i18n.dart';
import '../../models/chat_user.dart';
import '../../theme/chat_theme.dart';

/// Initials of a display name ("Ann Lee" gives "AL").
String initialsOf(String input) {
  final parts = input
      .trim()
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  String first(String v) => v.characters.first;
  if (parts.length == 1) return first(parts.first).toUpperCase();
  return (first(parts.first) + first(parts.last)).toUpperCase();
}

/// `HH:mm` of a timestamp in the device time zone.
String formatClock(int timestampMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

/// Day label for a list separator: Today, Yesterday or `YYYY-MM-DD`.
String formatDayLabel(int timestampMs, ChatStrings strings, {DateTime? now}) {
  final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(dt.year, dt.month, dt.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return strings.t('date.today');
  if (diff == 1) return strings.t('date.yesterday');
  final mm = dt.month.toString().padLeft(2, '0');
  final dd = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$mm-$dd';
}

bool sameDay(int aMs, int bMs) {
  final a = DateTime.fromMillisecondsSinceEpoch(aMs);
  final b = DateTime.fromMillisecondsSinceEpoch(bMs);
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Round avatar: the user's photo when there is one, else initials.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.user,
    this.radius = 14,
    this.nameOverride,
  });

  final ChatUser user;
  final double radius;
  final String? nameOverride;

  @override
  Widget build(BuildContext context) {
    final theme = ChatUiScope.of(context).theme;
    final name = nameOverride ?? user.displayName;
    final photo = (user.photoUrl ?? '').trim();
    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: theme.primarySoft,
      child: Text(
        initialsOf(name),
        style: TextStyle(
          fontSize: radius * 0.72,
          color: theme.primaryText,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    if (photo.isEmpty || !photo.startsWith('http')) return fallback;
    return CircleAvatar(
      radius: radius,
      backgroundColor: theme.primarySoft,
      child: ClipOval(
        child: Image.network(
          photo,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback,
        ),
      ),
    );
  }
}
