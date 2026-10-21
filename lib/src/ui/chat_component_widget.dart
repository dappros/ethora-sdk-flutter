import 'package:flutter/material.dart';

import '../core/chat_component_controller.dart';
import '../core/chat_component_state.dart';
import '../i18n/chat_i18n.dart';
import '../models/chat_component_config.dart';
import '../models/chat_room.dart';
import '../theme/chat_theme.dart';
import 'conversation/conversation_pane.dart';
import '../networking/message_search_service.dart';
import 'calls/call_header_buttons.dart';
import 'calls/call_overlay_host.dart';
import 'rooms/room_info_sheet.dart';
import 'rooms/room_list_view.dart';
import 'search/message_search_page.dart';
import 'settings/chat_settings_screen.dart';

/// Width from which the room list and the open chat sit side by side.
const double kChatSplitBreakpoint = 720;

class ChatComponent extends StatefulWidget {
  const ChatComponent({
    super.key,
    required this.controller,
    required this.config,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;

  @override
  State<ChatComponent> createState() => _ChatComponentState();
}

class _ChatComponentState extends State<ChatComponent> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _jwtController = TextEditingController();

  bool _showJwtForm = false;
  bool _isLoggingIn = false;

  /// Phone layout: the room list is a page of its own; false shows the chat.
  bool _phoneShowsList = true;

  ChatTheme? _theme;
  ChatStrings? _strings;
  String? _themeKey;
  String? _stringsKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.initialize();
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _jwtController.dispose();
    super.dispose();
  }

  ChatTheme _resolveTheme(BuildContext context) {
    final config = widget.config;
    final platform = MediaQuery.platformBrightnessOf(context);
    final key = '${config.colorScheme}|$platform|${identityHashCode(config.colors)}|'
        '${identityHashCode(config.typography)}';
    if (_theme == null || _themeKey != key) {
      _theme = ChatTheme.from(
        colors: config.colors,
        typography: config.typography,
        scheme: config.colorScheme ?? ChatColorScheme.light,
        platformBrightness: platform,
      );
      _themeKey = key;
    }
    return _theme!;
  }

  ChatStrings _resolveStrings(ChatComponentState state) {
    final locale = state.user?.appLanguage ?? widget.config.i18n?.locale;
    final key = '$locale|${identityHashCode(widget.config.i18n?.strings)}';
    if (_strings == null || _stringsKey != key) {
      _strings = ChatStrings.resolve(locale, widget.config.i18n?.strings);
      _stringsKey = key;
    }
    return _strings!;
  }

  @override
  Widget build(BuildContext context) {
    final theme = _resolveTheme(context);
    return ValueListenableBuilder<ChatComponentState>(
      valueListenable: widget.controller.state,
      builder: (context, state, _) {
        final strings = _resolveStrings(state);
        return Theme(
          data: theme.toThemeData(),
          child: ChatUiScope(
            theme: theme,
            strings: strings,
            child: Builder(
              builder: (context) => theme.scopeText(
                context,
                Material(
                  color: theme.bg,
                  child: CallOverlayHost(
                    controller: widget.controller,
                    config: widget.config,
                    child: _buildBody(context, state, strings, theme),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    ChatComponentState state,
    ChatStrings strings,
    ChatTheme theme,
  ) {
    if (state.isLoading && !state.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.requiresLogin) {
      return _LoginCard(
        showJwtForm: _showJwtForm,
        isLoggingIn: _isLoggingIn,
        emailController: _emailController,
        passwordController: _passwordController,
        jwtController: _jwtController,
        onModeChanged: (value) => setState(() => _showJwtForm = value),
        onLoginEmail: () => _login(
          () => widget.controller.loginEmail(
            _emailController.text.trim(),
            _passwordController.text,
          ),
        ),
        onLoginJwt: () => _login(
          () => widget.controller.loginJwt(_jwtController.text.trim()),
        ),
      );
    }
    if ((state.errorMessage ?? '').isNotEmpty && !state.isInitialized) {
      return Center(
        child: Text(state.errorMessage!, style: TextStyle(color: theme.danger)),
      );
    }
    return _buildChat(context, state);
  }

  Future<void> _login(Future<Object?> Function() action) async {
    setState(() => _isLoggingIn = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(_errorText(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoggingIn = false);
    }
  }

  String _errorText(Object error) {
    final strings = ChatUiScope.of(context).strings;
    final text = error.toString();
    if (text.contains('401') || text.contains('403')) {
      return strings.t('toast.invalidCredentials');
    }
    return strings.t('toast.loginErrorMessage');
  }

  ChatRoom? _selectedRoom(ChatComponentState state) {
    if (state.rooms.isEmpty) return null;
    if (state.selectedRoomJid == null) return state.rooms.first;
    return state.rooms
            .where((e) => e.jid == state.selectedRoomJid)
            .firstOrNull ??
        state.rooms.first;
  }

  Widget _buildChat(BuildContext context, ChatComponentState state) {
    final config = widget.config;
    final controller = widget.controller;
    final theme = ChatUiScope.of(context).theme;
    final room = _selectedRoom(state);
    final roomListEnabled =
        config.disableRooms != true && (config.roomJID ?? '').trim().isEmpty;
    final wide = MediaQuery.sizeOf(context).width >= kChatSplitBreakpoint;

    final jump = _jumpFor(state, room);

    Widget conversation({VoidCallback? onBack}) => ConversationPane(
          controller: controller,
          config: config,
          state: state,
          room: room,
          onBack: onBack,
          jump: jump,
          headerActions: _headerActions(context, room),
          onTitleTap: room == null ||
                  config.chatHeaderSettings?.chatInfoButtonDisabled == true ||
                  config.disableRoomMenu == true
              ? null
              : () => showRoomInfo(
                    context,
                    controller: controller,
                    config: config,
                    roomJid: room.jid,
                  ),
          onQuoteTap: room == null
              ? null
              : (parentId) => controller.jumpToMessage(
                    roomJid: room.jid,
                    ids: <String>[parentId],
                  ),
        );

    Widget list() => RoomListView(
          controller: controller,
          config: config,
          selectedRoomJid: room?.jid,
          onOpenSettings: () => showChatSettings(
            context,
            controller: controller,
            config: config,
          ),
          onSelectRoom: (jid) {
            controller.selectRoom(jid);
            setState(() => _phoneShowsList = false);
          },
        );

    if (wide && roomListEnabled) {
      return Row(
        children: [
          SizedBox(width: 320, child: list()),
          VerticalDivider(width: 1, color: theme.border),
          Expanded(child: conversation()),
        ],
      );
    }
    if (roomListEnabled) {
      if (_phoneShowsList) return list();
      return conversation(
        onBack: config.chatHeaderSettings?.backButtonDisabled == true
            ? null
            : () => setState(() => _phoneShowsList = true),
      );
    }
    return conversation();
  }

  List<Widget> _headerActions(BuildContext context, ChatRoom? room) {
    final ui = ChatUiScope.of(context);
    final config = widget.config;
    final controller = widget.controller;
    return <Widget>[
      if (room != null)
        CallHeaderButtons(controller: controller, config: config, room: room),
      if (room != null &&
          isMessageSearchEnabled(config) &&
          config.chatHeaderSettings?.hideSearch != true)
        IconButton(
          tooltip: ui.strings.t('search.messages.title'),
          onPressed: () => showMessageSearch(
            context,
            controller: controller,
            config: config,
            roomJid: room.jid,
            onOpenRoom: (_) => setState(() => _phoneShowsList = false),
          ),
          icon: Icon(Icons.search, color: ui.theme.icons),
        ),
      IconButton(
        tooltip: ui.strings.t('settings.menu.title'),
        onPressed: () => showChatSettings(
          context,
          controller: controller,
          config: config,
        ),
        icon: Icon(Icons.settings_outlined, color: ui.theme.icons),
      ),
    ];
  }

  int _handledThreadJump = -1;

  /// Maps the controller's jump state onto what the conversation shows: the
  /// archive window instead of the live list, the target to scroll to, and
  /// the thread to open for a thread-only reply.
  ConversationJump _jumpFor(ChatComponentState state, ChatRoom? room) {
    if (room == null) return const ConversationJump();
    final window = state.jumpWindowByRoom[room.jid];
    final target = state.jumpTarget;
    final targetHere = target != null && target.roomJid == room.jid;
    if (targetHere &&
        target.threadRootId != null &&
        _handledThreadJump != target.nonce) {
      _handledThreadJump = target.nonce;
      final root = target.threadRootId!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.openThreadById(room.jid, root);
      });
    }
    return ConversationJump(
      messages: (window != null && window.isNotEmpty) ? window : null,
      targetId: targetHere && target.threadRootId == null
          ? target.messageId
          : null,
      nonce: targetHere ? target.nonce : 0,
      onJumpToLatest: (window != null && window.isNotEmpty)
          ? () => widget.controller.clearJumpWindow(room.jid)
          : null,
    );
  }
}

class _LoginCard extends StatelessWidget {
  const _LoginCard({
    required this.showJwtForm,
    required this.isLoggingIn,
    required this.emailController,
    required this.passwordController,
    required this.jwtController,
    required this.onModeChanged,
    required this.onLoginEmail,
    required this.onLoginJwt,
  });

  final bool showJwtForm;
  final bool isLoggingIn;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final TextEditingController jwtController;
  final ValueChanged<bool> onModeChanged;
  final Future<void> Function() onLoginEmail;
  final Future<void> Function() onLoginJwt;

  @override
  Widget build(BuildContext context) {
    final ui = ChatUiScope.of(context);
    final strings = ui.strings;
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    strings.t('login.title'),
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: ui.theme.text,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment<bool>(
                        value: false,
                        label: Text(strings.t('field.email')),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        label: Text(strings.t('login.tabJwt')),
                      ),
                    ],
                    selected: <bool>{showJwtForm},
                    onSelectionChanged: (values) => onModeChanged(values.first),
                  ),
                  const SizedBox(height: 16),
                  if (!showJwtForm) ...[
                    TextField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: strings.t('field.email'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: passwordController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: strings.t('field.password'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: isLoggingIn ? null : onLoginEmail,
                      child: Text(
                        isLoggingIn
                            ? strings.t('login.signingIn')
                            : strings.t('login.submitEmail'),
                      ),
                    ),
                  ] else ...[
                    TextField(
                      controller: jwtController,
                      minLines: 4,
                      maxLines: 8,
                      decoration: InputDecoration(
                        labelText: strings.t('login.jwtField'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: isLoggingIn ? null : onLoginJwt,
                      child: Text(
                        isLoggingIn
                            ? strings.t('login.signingIn')
                            : strings.t('login.submitJwt'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
