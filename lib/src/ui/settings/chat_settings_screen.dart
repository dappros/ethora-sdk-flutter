import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/chat_component_controller.dart';
import '../../core/chat_component_state.dart';
import '../../i18n/chat_i18n.dart';
import '../../models/chat_component_config.dart';
import '../../models/chat_user.dart';
import '../../networking/api_client.dart';
import '../../theme/chat_theme.dart';

/// Width from which settings open as a dialog instead of a full page.
const double kSettingsDialogBreakpoint = 720;

/// Interface and chat language choices when the host passes none.
const List<ChatLanguageOption> kDefaultLanguageOptions = <ChatLanguageOption>[
  ChatLanguageOption(id: 'en-CA', name: 'English'),
  ChatLanguageOption(id: 'es-US', name: 'Español'),
  ChatLanguageOption(id: 'fr-CA', name: 'Français'),
];

/// File name offered to `settings.onExportData`.
const String kExportFileName = 'ethora-data-export.json';

/// Longest slice of an export shown in the copyable dialog. Copy always
/// puts the whole export on the clipboard.
const int _kExportPreviewChars = 20000;

/// Opens the account settings: a full-page route on phones, a dialog on wide
/// screens. Languages, change password, manage data (export and delete), the
/// push switch and the logout button, each only when configured.
Future<void> showChatSettings(
  BuildContext context, {
  required ChatComponentController controller,
  required ChatComponentConfig config,
}) {
  final theme = ChatUiScope.of(context).theme;
  final wide = MediaQuery.sizeOf(context).width >= kSettingsDialogBreakpoint;
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        clipBehavior: Clip.antiAlias,
        backgroundColor: theme.bg,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 760),
          child: _SettingsHost(
            theme: theme,
            controller: controller,
            config: config,
            inDialog: true,
          ),
        ),
      ),
    );
  }
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (routeContext) => _SettingsHost(
        theme: theme,
        controller: controller,
        config: config,
        inDialog: false,
      ),
    ),
  );
}

/// Asks to confirm (unless `config.logout.confirm` is false) and signs out.
/// Does nothing when `config.logout.enabled` is false. For the chat header's
/// logout button.
Future<void> confirmAndLogout(
  BuildContext context, {
  required ChatComponentController controller,
  required ChatComponentConfig config,
}) async {
  final logout = config.logout;
  if (logout != null && !logout.enabled) return;
  final strings = ChatUiScope.of(context).strings;
  if (logout?.confirm != false) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.t('logout.confirmTitle')),
        content: Text(strings.t('logout.confirmDescription')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.t('action.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.t('action.logOut')),
          ),
        ],
      ),
    );
    if (ok != true) return;
  }
  await controller.logout();
}

/// Builds the theme and live strings (they follow the account language the
/// moment it changes) around the settings page, which sits in its own route
/// and so cannot inherit the chat widget's [ChatUiScope].
class _SettingsHost extends StatelessWidget {
  const _SettingsHost({
    required this.theme,
    required this.controller,
    required this.config,
    required this.inDialog,
  });

  final ChatTheme theme;
  final ChatComponentController controller;
  final ChatComponentConfig config;
  final bool inDialog;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ChatComponentState>(
      valueListenable: controller.state,
      builder: (context, state, _) {
        final strings = ChatStrings.resolve(
          controller.uiLocale,
          config.i18n?.strings,
        );
        return Theme(
          data: theme.toThemeData(),
          child: ChatUiScope(
            theme: theme,
            strings: strings,
            child: Builder(
              builder: (context) => theme.scopeText(
                context,
                ChatSettingsScreen(
                  controller: controller,
                  config: config,
                  inDialog: inDialog,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class ChatSettingsScreen extends StatefulWidget {
  const ChatSettingsScreen({
    super.key,
    required this.controller,
    required this.config,
    this.inDialog = false,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;
  final bool inDialog;

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  bool _busy = false;
  bool _pushLoaded = false;

  ChatComponentController get _controller => widget.controller;
  ChatSettingsConfig? get _settings => widget.config.settings;

  @override
  void initState() {
    super.initState();
    _controller.loadPushPreferences().then((_) {
      if (mounted) setState(() => _pushLoaded = true);
    });
  }

  ChatStrings get _strings => ChatUiScope.of(context).strings;
  ChatTheme get _theme => ChatUiScope.of(context).theme;

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _failure(Object error, String fallback) {
    if (error is ApiException) return error.reason ?? fallback;
    return fallback;
  }

  Future<void> _setLanguage({required bool app, required String id}) async {
    try {
      if (app) {
        await _controller.setAppLanguage(id);
      } else {
        await _controller.setChatLanguage(id);
      }
    } catch (error) {
      if (mounted) _toast(_failure(error, _strings.t('toast.error')));
    }
  }

  Future<void> _setPush(bool enabled) async {
    try {
      await _controller.setPushEnabled(enabled);
    } catch (error) {
      if (mounted) _toast(_failure(error, _strings.t('toast.error')));
    }
    if (mounted) setState(() {});
  }

  Future<void> _changePassword() async {
    final strings = _strings;
    final done = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _ChangePasswordDialog(
        controller: _controller,
        strings: strings,
        failureText: _failure,
      ),
    );
    if (done == true && mounted) {
      _toast(strings.t('settings.changePassword.done'));
    }
  }

  Future<void> _exportData() async {
    final strings = _strings;
    setState(() => _busy = true);
    try {
      final bytes = await _controller.exportMyData();
      if (!mounted) return;
      final onExport = _settings?.onExportData;
      if (onExport != null) {
        await onExport(bytes, kExportFileName);
        if (mounted) _toast(strings.t('settings.manageData.exported'));
      } else {
        // The dialog is modal: drop the busy overlay before it opens.
        setState(() => _busy = false);
        await _showExportDialog(bytes);
      }
    } catch (error) {
      if (mounted) {
        _toast(_failure(error, strings.t('settings.manageData.exportFailed')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The SDK carries no file-system dependency, so without a host
  /// `onExportData` the export is shown for copying.
  Future<void> _showExportDialog(List<int> bytes) {
    final strings = _strings;
    var text = utf8.decode(bytes, allowMalformed: true);
    try {
      text = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
    } catch (_) {
      // Not JSON: show it as received.
    }
    final preview = text.length > _kExportPreviewChars
        ? '${text.substring(0, _kExportPreviewChars)}\n...'
        : text;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.t('settings.manageData.downloadLabel')),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectableText(
              preview,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
              if (mounted) _toast(strings.t('settings.manageData.exported'));
            },
            child: Text(strings.t('action.copy')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.t('action.close')),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteAccount() async {
    final strings = _strings;
    final theme = _theme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.t('settings.manageData.deleteConfirmTitle')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(strings.t('settings.manageData.deleteConfirmDescription')),
              const SizedBox(height: 12),
              Text(
                strings.t('settings.manageData.deleteDisclosure'),
                style: TextStyle(fontSize: 12, color: theme.textMuted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.t('action.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              strings.t('action.delete'),
              style: TextStyle(color: theme.danger),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _controller.deleteAccount();
      _closeAfterSignOut();
    } catch (error) {
      if (mounted) {
        _toast(
          _failure(error, strings.t('settings.manageData.deleteFailed')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    await confirmAndLogout(
      context,
      controller: _controller,
      config: widget.config,
    );
    if (mounted) _closeAfterSignOut();
  }

  /// Settings has nothing to show once the session is gone.
  void _closeAfterSignOut() {
    if (!_controller.state.value.requiresLogin) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final strings = _strings;
    final theme = _theme;
    final user = _controller.state.value.user;
    final languages = _settings?.languages;
    final showLanguages = languages?.enabled == true;
    final showPassword = _settings?.changePassword == true;
    final showPush = _controller.pushConfigured &&
        _settings?.hidePushToggle != true &&
        _pushLoaded;
    final showLogout = widget.config.logout?.enabled != false;

    return Scaffold(
      backgroundColor: theme.bg,
      appBar: AppBar(
        backgroundColor: theme.bg,
        foregroundColor: theme.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          strings.t('settings.menu.title'),
          style: TextStyle(color: theme.text, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (widget.inDialog)
            IconButton(
              tooltip: strings.t('action.close'),
              icon: Icon(Icons.close_rounded, color: theme.icons),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
        ],
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _SectionTitle(strings.t('settings.account')),
              _AccountHeader(user: user),
              if (showLanguages) ...[
                _SectionTitle(strings.t('settings.languages.title')),
                _LanguagePicker(
                  label: strings.t('settings.languages.app'),
                  hint: strings.t('language.select'),
                  value: user?.appLanguage,
                  options: languages?.appLanguages ?? kDefaultLanguageOptions,
                  onChanged: (id) => _setLanguage(app: true, id: id),
                ),
                const SizedBox(height: 12),
                _LanguagePicker(
                  label: strings.t('settings.languages.chat'),
                  hint: strings.t('language.select'),
                  value: user?.chatLanguage,
                  options: languages?.chatLanguages ?? kDefaultLanguageOptions,
                  onChanged: (id) => _setLanguage(app: false, id: id),
                ),
              ],
              if (showPush) ...[
                _SectionTitle(strings.t('modal.chatProfile.notifications')),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    strings.t('settings.push.title'),
                    style: TextStyle(color: theme.text),
                  ),
                  value: _controller.pushEnabledByUser,
                  onChanged: _setPush,
                ),
              ],
              if (showPassword) ...[
                _SectionTitle(strings.t('settings.changePassword.title')),
                _ActionTile(
                  icon: Icons.lock_outline_rounded,
                  label: strings.t('settings.changePassword.submit'),
                  onTap: _busy ? null : _changePassword,
                ),
              ],
              _SectionTitle(strings.t('settings.manageData.title')),
              _ActionTile(
                icon: Icons.download_rounded,
                label: strings.t('settings.manageData.downloadLabel'),
                description:
                    strings.t('settings.manageData.downloadDescription'),
                onTap: _busy ? null : _exportData,
              ),
              const SizedBox(height: 8),
              _ActionTile(
                icon: Icons.delete_outline_rounded,
                label: strings.t('settings.manageData.deleteLabel'),
                description: strings.t('settings.manageData.deleteDescription'),
                danger: true,
                onTap: _busy ? null : _deleteAccount,
              ),
              if (showLogout) ...[
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _logout,
                  icon: Icon(Icons.logout, color: theme.danger),
                  label: Text(
                    strings.t('action.logOut'),
                    style: TextStyle(color: theme.danger),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: theme.danger),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ],
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = ChatUiScope.of(context).theme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: theme.textMuted,
        ),
      ),
    );
  }
}

class _AccountHeader extends StatelessWidget {
  const _AccountHeader({required this.user});

  final ChatUser? user;

  @override
  Widget build(BuildContext context) {
    final theme = ChatUiScope.of(context).theme;
    final name = user?.displayName ?? '';
    final email = user?.email ?? '';
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final photo = user?.photoUrl;
    return Row(
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: theme.primarySoft,
          foregroundImage: (photo ?? '').isEmpty ? null : NetworkImage(photo!),
          child: Text(
            initial,
            style: TextStyle(
              color: theme.primaryText,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: theme.text,
                ),
              ),
              if (email.isNotEmpty)
                Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: theme.textSecondary),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LanguagePicker extends StatelessWidget {
  const _LanguagePicker({
    required this.label,
    required this.hint,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String hint;
  final String? value;
  final List<ChatLanguageOption> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = ChatUiScope.of(context).theme;
    // A stored language outside the list (a regional variant the host does
    // not offer) still shows as selected rather than crashing the dropdown.
    final current = options.any((o) => o.id == value) ? value : null;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: current,
          isExpanded: true,
          hint: Text(hint),
          dropdownColor: theme.bg,
          items: [
            for (final option in options)
              DropdownMenuItem<String>(
                value: option.id,
                child: Text(option.name, style: TextStyle(color: theme.text)),
              ),
          ],
          onChanged: (id) {
            if (id != null && id != value) onChanged(id);
          },
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.description,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final String? description;
  final bool danger;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ChatUiScope.of(context).theme;
    final color = danger ? theme.danger : theme.text;
    return Material(
      color: theme.bgSubtle,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, color: danger ? theme.danger : theme.icons),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                    if (description != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        description!,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({
    required this.controller,
    required this.strings,
    required this.failureText,
  });

  final ChatComponentController controller;
  final ChatStrings strings;
  final String Function(Object error, String fallback) failureText;

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final strings = widget.strings;
    if (_next.text.length < 6) {
      setState(() => _error = strings.t('validation.passwordTooShort'));
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.controller.changePassword(
        currentPassword: _current.text,
        newPassword: _next.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = widget.failureText(
          error,
          strings.t('settings.changePassword.failed'),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final theme = ChatUiScope.of(context).theme;
    return AlertDialog(
      title: Text(strings.t('settings.changePassword.title')),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _current,
              obscureText: true,
              autofillHints: const <String>[AutofillHints.password],
              decoration: InputDecoration(
                labelText: strings.t('settings.changePassword.current'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _next,
              obscureText: true,
              autofillHints: const <String>[AutofillHints.newPassword],
              onSubmitted: (_) => _submitting ? null : _submit(),
              decoration: InputDecoration(
                labelText: strings.t('settings.changePassword.new'),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.danger, fontSize: 13),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: Text(strings.t('action.cancel')),
        ),
        TextButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(strings.t('settings.changePassword.submit')),
        ),
      ],
    );
  }
}
