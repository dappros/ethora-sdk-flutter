import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import '../core/chat_component_controller.dart';
import '../core/chat_component_state.dart';
import '../models/chat_component_config.dart';
import '../models/chat_message.dart';
import '../models/chat_room.dart';

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
  final _messageController = TextEditingController();

  bool _showJwtForm = false;
  bool _isLoggingIn = false;

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
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ChatComponentState>(
      valueListenable: widget.controller.state,
      builder: (context, state, _) {
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
            onLoginEmail: () async {
              setState(() => _isLoggingIn = true);
              try {
                await widget.controller.loginEmail(
                  _emailController.text.trim(),
                  _passwordController.text,
                );
              } finally {
                if (mounted) setState(() => _isLoggingIn = false);
              }
            },
            onLoginJwt: () async {
              setState(() => _isLoggingIn = true);
              try {
                await widget.controller.loginJwt(_jwtController.text.trim());
              } finally {
                if (mounted) setState(() => _isLoggingIn = false);
              }
            },
          );
        }
        if ((state.errorMessage ?? '').isNotEmpty && !state.isInitialized) {
          return Center(child: Text(state.errorMessage!));
        }
        return _ChatLayout(
          controller: widget.controller,
          config: widget.config,
          state: state,
          messageController: _messageController,
        );
      },
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
    return Center(
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
                const Text(
                  'Ethora Chat Login',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment<bool>(value: false, label: Text('Email')),
                    ButtonSegment<bool>(value: true, label: Text('JWT')),
                  ],
                  selected: <bool>{showJwtForm},
                  onSelectionChanged: (values) => onModeChanged(values.first),
                ),
                const SizedBox(height: 16),
                if (!showJwtForm) ...[
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: isLoggingIn ? null : onLoginEmail,
                    child: Text(
                        isLoggingIn ? 'Signing in...' : 'Login with Email'),
                  ),
                ] else ...[
                  TextField(
                    controller: jwtController,
                    minLines: 4,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText: 'JWT token',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: isLoggingIn ? null : onLoginJwt,
                    child:
                        Text(isLoggingIn ? 'Signing in...' : 'Login with JWT'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatLayout extends StatelessWidget {
  const _ChatLayout({
    required this.controller,
    required this.config,
    required this.state,
    required this.messageController,
  });

  final ChatComponentController controller;
  final ChatComponentConfig config;
  final ChatComponentState state;
  final TextEditingController messageController;

  @override
  Widget build(BuildContext context) {
    final selectedRoom = _selectedRoom(state);
    final messages = selectedRoom == null
        ? const <ChatMessage>[]
        : (state.messagesByRoom[selectedRoom.jid] ?? const <ChatMessage>[]);
    final wide = MediaQuery.sizeOf(context).width >= 920;
    final roomListEnabled = true;

    if (wide && roomListEnabled) {
      return Row(
        children: [
          SizedBox(
            width: 320,
            child: _RoomsPane(
              state: state,
              selectedRoomJid: selectedRoom?.jid,
              onSelectRoom: controller.selectRoom,
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _ConversationPane(
              state: state,
              room: selectedRoom,
              messages: messages,
              messageController: messageController,
              onSend: (text) =>
                  controller.sendText(selectedRoom?.jid ?? '', text),
              onPickAndSendFile: () async {
                final room = selectedRoom;
                if (room == null) return;
                final picked = await FilePicker.platform.pickFiles(
                  allowMultiple: false,
                  withData: true,
                );
                final file = picked?.files.firstOrNull;
                if (file == null || file.bytes == null) return;
                await controller.sendMedia(
                  room.jid,
                  bytes: file.bytes!,
                  filename: file.name,
                  mimeType: file.extension == null
                      ? 'application/octet-stream'
                      : _mimeByExtension(file.extension!),
                );
              },
              onTyping: (typing) {
                final room = selectedRoom;
                if (room != null) controller.setTyping(room.jid, typing);
              },
              onLogout: controller.logout,
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        if (roomListEnabled)
          _CompactRoomSelector(
            rooms: state.rooms,
            selectedRoomJid: selectedRoom?.jid,
            onSelectRoom: controller.selectRoom,
          ),
        Expanded(
          child: _ConversationPane(
            state: state,
            room: selectedRoom,
            messages: messages,
            messageController: messageController,
            onSend: (text) =>
                controller.sendText(selectedRoom?.jid ?? '', text),
            onPickAndSendFile: () async {
              final room = selectedRoom;
              if (room == null) return;
              final picked = await FilePicker.platform.pickFiles(
                allowMultiple: false,
                withData: true,
              );
              final file = picked?.files.firstOrNull;
              if (file == null || file.bytes == null) return;
              await controller.sendMedia(
                room.jid,
                bytes: file.bytes!,
                filename: file.name,
                mimeType: file.extension == null
                    ? 'application/octet-stream'
                    : _mimeByExtension(file.extension!),
              );
            },
            onTyping: (typing) {
              final room = selectedRoom;
              if (room != null) controller.setTyping(room.jid, typing);
            },
            onLogout: controller.logout,
          ),
        ),
      ],
    );
  }

  ChatRoom? _selectedRoom(ChatComponentState state) {
    if (state.rooms.isEmpty) return null;
    if (state.selectedRoomJid == null) return state.rooms.first;
    return state.rooms
            .where((e) => e.jid == state.selectedRoomJid)
            .firstOrNull ??
        state.rooms.first;
  }

  String _mimeByExtension(String ext) {
    final lower = ext.toLowerCase();
    if (lower == 'jpg' || lower == 'jpeg') return 'image/jpeg';
    if (lower == 'png') return 'image/png';
    if (lower == 'gif') return 'image/gif';
    if (lower == 'webp') return 'image/webp';
    if (lower == 'heic') return 'image/heic';
    if (lower == 'mp4') return 'video/mp4';
    if (lower == 'mov') return 'video/quicktime';
    if (lower == 'mp3') return 'audio/mpeg';
    if (lower == 'm4a') return 'audio/mp4';
    if (lower == 'aac') return 'audio/aac';
    if (lower == 'wav') return 'audio/wav';
    if (lower == 'pdf') return 'application/pdf';
    return 'application/octet-stream';
  }
}

class _RoomsPane extends StatelessWidget {
  const _RoomsPane({
    required this.state,
    required this.selectedRoomJid,
    required this.onSelectRoom,
  });

  final ChatComponentState state;
  final String? selectedRoomJid;
  final ValueChanged<String> onSelectRoom;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          alignment: Alignment.centerLeft,
          child: const Text(
            'Rooms',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: state.rooms.length,
            itemBuilder: (context, index) {
              final room = state.rooms[index];
              final isSelected = room.jid == selectedRoomJid;
              return ListTile(
                selected: isSelected,
                title: Text(room.title ?? room.jid),
                subtitle: room.composingList.isNotEmpty
                    ? Text('${room.composingList.join(", ")} typing...')
                    : Text(room.jid),
                trailing: room.pendingMessages > 0
                    ? _CountBadge(text: '${room.pendingMessages} sending')
                    : room.unreadCount > 0
                        ? _CountBadge(text: '${room.unreadCount}')
                        : null,
                onTap: () => onSelectRoom(room.jid),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _CompactRoomSelector extends StatelessWidget {
  const _CompactRoomSelector({
    required this.rooms,
    required this.selectedRoomJid,
    required this.onSelectRoom,
  });

  final List<ChatRoom> rooms;
  final String? selectedRoomJid;
  final ValueChanged<String> onSelectRoom;

  @override
  Widget build(BuildContext context) {
    final uniqueRoomsByJid = <String, ChatRoom>{};
    for (final room in rooms) {
      final jid = room.jid.trim();
      if (jid.isEmpty) continue;
      uniqueRoomsByJid.putIfAbsent(jid, () => room);
    }
    final effectiveRooms = uniqueRoomsByJid.values.toList();

    if (effectiveRooms.isEmpty) {
      return Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: const InputDecorator(
          decoration: InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Room',
          ),
          child: Text('No rooms available'),
        ),
      );
    }

    final roomJids = effectiveRooms.map((room) => room.jid).toSet();
    final String effectiveValue =
        (selectedRoomJid != null && roomJids.contains(selectedRoomJid))
            ? selectedRoomJid!
            : effectiveRooms.first.jid;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: DropdownButtonFormField<String>(
        key: ValueKey<String>(effectiveValue),
        initialValue: effectiveValue,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          labelText: 'Room',
        ),
        items: effectiveRooms
            .map(
              (room) => DropdownMenuItem<String>(
                value: room.jid,
                child: Text(room.title ?? room.jid,
                    overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: (value) {
          if (value != null) onSelectRoom(value);
        },
      ),
    );
  }
}

class _ConversationPane extends StatelessWidget {
  const _ConversationPane({
    required this.state,
    required this.room,
    required this.messages,
    required this.messageController,
    required this.onSend,
    required this.onPickAndSendFile,
    required this.onTyping,
    required this.onLogout,
  });

  final ChatComponentState state;
  final ChatRoom? room;
  final List<ChatMessage> messages;
  final TextEditingController messageController;
  final ValueChanged<String> onSend;
  final Future<void> Function() onPickAndSendFile;
  final ValueChanged<bool> onTyping;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    final hasRoom = room != null;
    final currentUsername =
        state.user?.username ?? state.user?.xmppUsername ?? state.user?.id;
    final connectionColor = switch (state.connectionState) {
      ChatConnectionState.online => Colors.green.shade600,
      ChatConnectionState.connecting => Colors.orange.shade600,
      ChatConnectionState.error => Colors.red.shade600,
      ChatConnectionState.offline => Colors.grey.shade600,
    };

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Colors.grey.shade200),
            ),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Attach file',
                onPressed: onPickAndSendFile,
                icon: const Icon(Icons.attach_file_rounded),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      room?.title ?? 'No room selected',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: connectionColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          state.connectionState.name,
                          style: TextStyle(
                            color: Colors.grey.shade700,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (room != null) ...[
                          const SizedBox(width: 10),
                          Text(
                            room!.jid,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onLogout,
                icon: const Icon(Icons.logout),
                tooltip: 'Logout',
              ),
            ],
          ),
        ),
        if ((state.errorMessage ?? '').isNotEmpty)
          Container(
            width: double.infinity,
            color: Colors.red.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              state.errorMessage!,
              style: TextStyle(color: Colors.red.shade800),
            ),
          ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.blueGrey.shade50,
                  Colors.white,
                ],
              ),
            ),
            child: hasRoom
                ? (messages.isEmpty
                    ? Center(
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.mark_chat_unread_outlined,
                                color: Colors.blueGrey.shade400,
                                size: 30,
                              ),
                              const SizedBox(height: 10),
                              const Text(
                                'No messages yet',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Send your first message to start conversation',
                                style: TextStyle(color: Colors.grey.shade600),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
                        itemCount: messages.length,
                        itemBuilder: (context, index) {
                          final msg = messages[messages.length - 1 - index];
                          final isMine = currentUsername != null &&
                              (msg.user.username == currentUsername ||
                                  msg.user.xmppUsername == currentUsername);
                          return _MessageBubble(message: msg, isMine: isMine);
                        },
                      ))
                : const Center(child: Text('Select a room to start chatting')),
          ),
        ),
        if (hasRoom && room!.composingList.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                '${room!.composingList.join(", ")} typing...',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Colors.grey.shade700,
                ),
              ),
            ),
          ),
        if (hasRoom)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.grey.shade200),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: messageController,
                        onChanged: (_) => onTyping(true),
                        decoration: const InputDecoration(
                          hintText: 'Write message...',
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: () {
                        final text = messageController.text.trim();
                        if (text.isEmpty) return;
                        messageController.clear();
                        onSend(text);
                      },
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Icon(Icons.send_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.isMine});

  final ChatMessage message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final bg = isMine ? Colors.blue.shade600 : Colors.white;
    final fg = isMine ? Colors.white : Colors.black87;
    final time = _messageTime(message.createdAtMs);
    final initials = _initials(message.user.displayName);
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580),
        child: Row(
          mainAxisAlignment:
              isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!isMine) ...[
              CircleAvatar(
                radius: 12,
                backgroundColor: Colors.blueGrey.shade100,
                child: Text(
                  initials,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.blueGrey.shade700,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 5),
                padding: const EdgeInsets.fromLTRB(12, 9, 12, 8),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(14),
                    topRight: const Radius.circular(14),
                    bottomLeft: Radius.circular(isMine ? 14 : 4),
                    bottomRight: Radius.circular(isMine ? 4 : 14),
                  ),
                  border: isMine
                      ? null
                      : Border.all(color: Colors.grey.shade200, width: 1),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: isMine ? 0.08 : 0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isMine)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          message.user.displayName,
                          style: TextStyle(
                            color: Colors.blueGrey.shade700,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    Text(
                      message.isMedia
                          ? '[media] ${message.mediaUrl}'
                          : message.text,
                      style: TextStyle(color: fg),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          time,
                          style: TextStyle(
                            fontSize: 10,
                            color: isMine
                                ? Colors.white.withValues(alpha: 0.78)
                                : Colors.grey.shade500,
                          ),
                        ),
                        if (message.pending) ...[
                          const SizedBox(width: 6),
                          Text(
                            'sending...',
                            style: TextStyle(
                              fontSize: 10,
                              color: isMine
                                  ? Colors.white.withValues(alpha: 0.78)
                                  : Colors.orange.shade700,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (isMine) ...[
              const SizedBox(width: 8),
              CircleAvatar(
                radius: 12,
                backgroundColor: Colors.blue.shade100,
                child: Text(
                  initials,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.blue.shade700,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _initials(String input) {
    final parts = input
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return _firstChar(parts.first).toUpperCase();
    }
    return (_firstChar(parts.first) + _firstChar(parts.last)).toUpperCase();
  }

  String _firstChar(String value) {
    if (value.isEmpty) return '';
    return value.substring(0, 1);
  }

  String _messageTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(color: Colors.blue.shade800, fontSize: 12),
      ),
    );
  }
}

extension _FirstOrNullExt<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
