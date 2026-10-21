import 'package:flutter/material.dart';

import '../i18n/chat_i18n.dart';
import '../models/chat_component_config.dart';

/// Resolved colours and typography for the SDK UI.
///
/// Built from the host's [ChatColors] and [ChatTypography] the same way the
/// web SDK builds its `--ethora-*` tokens (`styles/tokens.ts`): the light
/// defaults are the web defaults, and the dark palette uses the web dark
/// neutrals. Primary is lifted in dark so primary-coloured text stays
/// readable, while buttons keep white text on it.
class ChatTheme {
  const ChatTheme({
    required this.brightness,
    required this.primary,
    required this.primaryHover,
    required this.primaryText,
    required this.primarySoft,
    required this.secondary,
    required this.icons,
    required this.iconsBg,
    required this.iconChipBg,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.textOnPrimary,
    required this.bg,
    required this.bgSubtle,
    required this.bgHover,
    required this.border,
    required this.danger,
    required this.success,
    required this.online,
    required this.chatBg,
    required this.divider,
    required this.ownMessageBackground,
    required this.otherMessageBackground,
    required this.inputBackground,
    this.fontFamily,
    this.fontScale = 1,
  });

  final Brightness brightness;
  final Color primary;
  final Color primaryHover;
  final Color primaryText;
  final Color primarySoft;
  final Color secondary;
  final Color icons;
  final Color iconsBg;
  final Color iconChipBg;
  final Color text;
  final Color textSecondary;
  final Color textMuted;
  final Color textOnPrimary;
  final Color bg;
  final Color bgSubtle;
  final Color bgHover;
  final Color border;
  final Color danger;
  final Color success;
  final Color online;
  final Color chatBg;
  final Color divider;
  final Color ownMessageBackground;
  final Color otherMessageBackground;
  final Color inputBackground;

  /// Family applied to all SDK text. Null keeps the host's default font.
  final String? fontFamily;

  /// Multiplier on the Material text scale. `fontSize / 16`.
  final double fontScale;

  bool get isDark => brightness == Brightness.dark;

  /// The default light theme, equal to the web defaults.
  factory ChatTheme.light() => ChatTheme.from();

  /// Builds the theme for the given config. [platformBrightness] is used
  /// when [scheme] is `system`.
  factory ChatTheme.from({
    ChatColors? colors,
    ChatTypography? typography,
    ChatColorScheme scheme = ChatColorScheme.light,
    Brightness platformBrightness = Brightness.light,
  }) {
    final dark = switch (scheme) {
      ChatColorScheme.dark => true,
      ChatColorScheme.light => false,
      ChatColorScheme.system => platformBrightness == Brightness.dark,
    };
    final base = dark ? _dark : _light;

    final configuredPrimary = _hex(colors?.primary) ?? _defaultPrimary;
    final customPrimary = _hex(colors?.primary) != null;
    // Lift the brand colour in dark so primary text and icons stay legible.
    final primary = dark ? _tint(configuredPrimary, 0.2) : configuredPrimary;
    final primaryText = dark ? _tint(configuredPrimary, 0.45) : primary;
    final primarySoft = dark
        ? _mix(configuredPrimary, base.bg, 0.72)
        : (customPrimary ? _tint(primary, 0.88) : _lightPrimarySoft);

    final secondary = _hex(colors?.secondary) ?? primary;
    final icons = _hex(colors?.icons) ?? primary;
    // Light falls back to the host `secondary`; dark does not, because a
    // light host secondary would paint a near-white chip on a dark surface.
    final iconsBg = dark
        ? (_hex(colors?.iconsBg) ?? base.iconsBg)
        : (_hex(colors?.iconsBg) ?? _hex(colors?.secondary) ?? base.iconsBg);

    final ownBg = _hex(colors?.ownMessageBackground) ??
        (dark ? primarySoft : _lightOwnMessageBg);
    final otherBg = _hex(colors?.otherMessageBackground) ??
        (dark ? base.bg : _lightOtherMessageBg);
    final inputBg = _hex(colors?.inputBackground) ??
        (dark ? base.bg : _lightInputBg);

    return ChatTheme(
      brightness: dark ? Brightness.dark : Brightness.light,
      primary: primary,
      primaryHover: _shade(primary, 0.08),
      primaryText: primaryText,
      primarySoft: primarySoft,
      secondary: secondary,
      icons: icons,
      iconsBg: iconsBg,
      iconChipBg: base.iconChipBg,
      text: base.text,
      textSecondary: base.textSecondary,
      textMuted: base.textMuted,
      textOnPrimary: _white,
      bg: base.bg,
      bgSubtle: base.bgSubtle,
      bgHover: base.bgHover,
      border: base.border,
      danger: base.danger,
      success: base.success,
      online: dark ? _darkOnline : base.success,
      chatBg: base.chatBg,
      divider: base.divider,
      ownMessageBackground: ownBg,
      otherMessageBackground: otherBg,
      inputBackground: inputBg,
      fontFamily: _fontFamily(typography?.fontFamily),
      fontScale: _fontScale(typography?.fontSize),
    );
  }

  /// Material theme for the SDK subtree, so Material widgets (fields,
  /// dialogs, menus, switches) follow the same palette.
  ThemeData toThemeData() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    ).copyWith(
      primary: primary,
      onPrimary: textOnPrimary,
      secondary: secondary,
      onSecondary: textOnPrimary,
      surface: bg,
      onSurface: text,
      outline: border,
      outlineVariant: divider,
      error: danger,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      dividerColor: divider,
      fontFamily: fontFamily,
      iconTheme: IconThemeData(color: icons),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderSide: BorderSide(color: border)),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: primary, width: 2),
        ),
      ),
    );
  }

  /// Applies [fontScale] to every Text under [child] by scaling the
  /// MediaQuery text scaler, so host text-scale settings still apply.
  Widget scopeText(BuildContext context, Widget child) {
    if (fontScale == 1) return child;
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        textScaler: TextScaler.linear(mq.textScaler.scale(1) * fontScale),
      ),
      child: child,
    );
  }

  static const Color _white = Color(0xFFFFFFFF);
  static const Color _defaultPrimary = Color(0xFF0052CD);
  static const Color _lightPrimarySoft = Color(0xFFE7EDF9);
  static const Color _lightOwnMessageBg = Color(0xFFE7EDF9);
  static const Color _lightOtherMessageBg = Color(0xFFFFFFFF);
  static const Color _lightInputBg = Color(0xFFFFFFFF);
  static const Color _darkOnline = Color(0xFF3DD68C);

  static const _light = _Neutrals(
    text: Color(0xFF141414),
    textSecondary: Color(0xFF5A5F66),
    textMuted: Color(0xFF6C6C6C),
    bg: Color(0xFFFFFFFF),
    bgSubtle: Color(0xFFF5F7FA),
    bgHover: Color(0xFFF0F2F5),
    border: Color(0xFFE6E8EC),
    danger: Color(0xFFD02B1F),
    success: Color(0xFF0C7C48),
    chatBg: Color(0xFFF3F6FC),
    divider: Color(0xFFE6E8EC),
    iconChipBg: Color(0xFFF0F3F7),
    iconsBg: Color(0xFFFFFFFF),
  );

  static const _dark = _Neutrals(
    text: Color(0xFFECEEF1),
    textSecondary: Color(0xFFB4B9C1),
    textMuted: Color(0xFF9AA1AB),
    bg: Color(0xFF1A1C21),
    bgSubtle: Color(0xFF202329),
    bgHover: Color(0xFF2A2D34),
    border: Color(0xFF34373F),
    danger: Color(0xFFF2766B),
    success: Color(0xFF17864A),
    chatBg: Color(0xFF141619),
    divider: Color(0xFF0F1114),
    iconChipBg: Color(0xFF2A2D34),
    iconsBg: Color(0xFF24272D),
  );

  static Color? _hex(String? value) {
    if (value == null) return null;
    var h = value.trim();
    if (h.startsWith('#')) h = h.substring(1);
    if (h.length == 3) {
      h = h.split('').map((c) => '$c$c').join();
    }
    if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(h)) return null;
    return Color(0xFF000000 | int.parse(h, radix: 16));
  }

  static int _ch(Color c, int shift) => (c.toARGB32() >> shift) & 0xFF;

  static Color _rgb(double r, double g, double b) {
    return Color(0xFF000000 | (_byte(r) << 16) | (_byte(g) << 8) | _byte(b));
  }

  static int _byte(double v) {
    final r = v.round();
    if (r < 0) return 0;
    if (r > 255) return 255;
    return r;
  }

  /// Mix toward white by [amount] (0 to 1), as web `tintColor`.
  static Color _tint(Color c, double amount) => _rgb(
        _ch(c, 16) + (255 - _ch(c, 16)) * amount,
        _ch(c, 8) + (255 - _ch(c, 8)) * amount,
        _ch(c, 0) + (255 - _ch(c, 0)) * amount,
      );

  /// Mix toward black by [amount], as web `shadeColor`.
  static Color _shade(Color c, double amount) => _rgb(
        _ch(c, 16) * (1 - amount),
        _ch(c, 8) * (1 - amount),
        _ch(c, 0) * (1 - amount),
      );

  /// Mix [a] toward [b] by [amount], as web `mixColor`.
  static Color _mix(Color a, Color b, double amount) => _rgb(
        _ch(a, 16) + (_ch(b, 16) - _ch(a, 16)) * amount,
        _ch(a, 8) + (_ch(b, 8) - _ch(a, 8)) * amount,
        _ch(a, 0) + (_ch(b, 0) - _ch(a, 0)) * amount,
      );

  static String? _fontFamily(String? raw) {
    if (raw == null) return null;
    final first = raw.split(',').first.trim().replaceAll(RegExp('["\']'), '');
    return first.isEmpty ? null : first;
  }

  /// Base size as a multiplier of 16 px. Accepts a number (pixels), or a
  /// string with `px`, `rem`, `em` or no unit (pixels).
  static double _fontScale(Object? size) {
    double? px;
    if (size is num) {
      px = size.toDouble();
    } else if (size is String) {
      final s = size.trim().toLowerCase();
      if (s.endsWith('rem') || s.endsWith('em')) {
        final n = double.tryParse(s.replaceAll(RegExp(r'[a-z]'), ''));
        px = n == null ? null : n * 16;
      } else {
        px = double.tryParse(s.replaceAll(RegExp(r'[a-z]'), ''));
      }
    }
    if (px == null || px <= 0) return 1;
    return px / 16;
  }
}

/// Dark or light neutrals for one scheme.
class _Neutrals {
  const _Neutrals({
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.bg,
    required this.bgSubtle,
    required this.bgHover,
    required this.border,
    required this.danger,
    required this.success,
    required this.chatBg,
    required this.divider,
    required this.iconChipBg,
    required this.iconsBg,
  });

  final Color text;
  final Color textSecondary;
  final Color textMuted;
  final Color bg;
  final Color bgSubtle;
  final Color bgHover;
  final Color border;
  final Color danger;
  final Color success;
  final Color chatBg;
  final Color divider;
  final Color iconChipBg;
  final Color iconsBg;
}

/// Provides [ChatTheme] and [ChatStrings] to the SDK widgets below it.
class ChatUiScope extends InheritedWidget {
  const ChatUiScope({
    super.key,
    required this.theme,
    required this.strings,
    required super.child,
  });

  final ChatTheme theme;
  final ChatStrings strings;

  /// The scope above [context], or the English light defaults when the SDK
  /// widget is used without one.
  static ChatUiScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ChatUiScope>();
    if (scope != null) return scope;
    return ChatUiScope(
      theme: ChatTheme.light(),
      strings: ChatStrings.resolve(null, null),
      child: const SizedBox.shrink(),
    );
  }

  @override
  bool updateShouldNotify(ChatUiScope oldWidget) =>
      oldWidget.theme != theme || oldWidget.strings != strings;
}
