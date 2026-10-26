import '../models/chat_message.dart';
import '../models/chat_room.dart';
import '../models/chat_user.dart';

enum ChatConnectionState { offline, connecting, online, error }

/// Message being edited in the composer (web `editAction`).
class ChatEditDraft {
  const ChatEditDraft({
    required this.roomJid,
    required this.messageId,
    required this.text,
  });

  final String roomJid;
  final String messageId;
  final String text;
}

/// The open thread panel: the root message [rootId] (archive id) of [roomJid].
class ChatThreadRef {
  const ChatThreadRef({required this.roomJid, required this.rootId});

  final String roomJid;
  final String rootId;
}

/// A message the UI should scroll to and flash (search hit, quote tap, push
/// tap). A new [nonce] re-triggers the scroll even for the same message.
class ChatJumpTarget {
  const ChatJumpTarget({
    required this.roomJid,
    required this.messageId,
    required this.nonce,
    this.threadRootId,
  });

  final String roomJid;

  /// Archive id of the target, as it appears in the list that holds it
  /// (the live list or [ChatComponentState.jumpWindowByRoom]).
  final String messageId;
  final int nonce;

  /// Set when the target is a thread-only reply: the UI opens this root's
  /// thread and highlights the reply there instead of in the main list.
  final String? threadRootId;

  /// Alias of [threadRootId] (web `replyParentId`).
  String? get replyParentId => threadRootId;
}

class ChatComponentState {
  const ChatComponentState({
    this.isInitialized = false,
    this.isLoading = false,
    this.requiresLogin = false,
    this.errorMessage,
    this.user,
    this.connectionState = ChatConnectionState.offline,
    this.rooms = const <ChatRoom>[],
    this.messagesByRoom = const <String, List<ChatMessage>>{},
    this.selectedRoomJid,
    this.roomEpoch = const <String, int>{},
    this.pendingSendById = const <String, String>{},
    this.globalLoading = false,
    this.loadingText,
    this.editDraft,
    this.activeThread,
    this.jumpWindowByRoom = const <String, List<ChatMessage>>{},
    this.jumpTarget,
  });

  final bool isInitialized;
  final bool isLoading;
  final bool requiresLogin;
  final String? errorMessage;
  final ChatUser? user;
  final ChatConnectionState connectionState;
  final List<ChatRoom> rooms;
  final Map<String, List<ChatMessage>> messagesByRoom;
  final String? selectedRoomJid;
  final Map<String, int> roomEpoch;
  final Map<String, String> pendingSendById;
  final bool globalLoading;
  final String? loadingText;

  /// Non-null while the composer edits an existing message.
  final ChatEditDraft? editDraft;

  /// Non-null while a thread panel is open.
  final ChatThreadRef? activeThread;

  /// A slice of archive around a jump target, per room. While a room has a
  /// non-empty entry the UI shows it INSTEAD of the live list, with a "Jump to
  /// latest" button that calls `controller.clearJumpWindow(roomJid)`.
  final Map<String, List<ChatMessage>> jumpWindowByRoom;

  /// The message to scroll to and highlight, if any.
  final ChatJumpTarget? jumpTarget;

  ChatComponentState copyWith({
    bool? isInitialized,
    bool? isLoading,
    bool? requiresLogin,
    String? errorMessage,
    bool clearErrorMessage = false,
    ChatUser? user,
    ChatConnectionState? connectionState,
    List<ChatRoom>? rooms,
    Map<String, List<ChatMessage>>? messagesByRoom,
    String? selectedRoomJid,
    Map<String, int>? roomEpoch,
    Map<String, String>? pendingSendById,
    bool? globalLoading,
    String? loadingText,
    ChatEditDraft? editDraft,
    bool clearEditDraft = false,
    ChatThreadRef? activeThread,
    bool clearActiveThread = false,
    bool clearSelectedRoom = false,
    Map<String, List<ChatMessage>>? jumpWindowByRoom,
    ChatJumpTarget? jumpTarget,
    bool clearJumpTarget = false,
  }) {
    return ChatComponentState(
      isInitialized: isInitialized ?? this.isInitialized,
      isLoading: isLoading ?? this.isLoading,
      requiresLogin: requiresLogin ?? this.requiresLogin,
      errorMessage:
          clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      user: user ?? this.user,
      connectionState: connectionState ?? this.connectionState,
      rooms: rooms ?? this.rooms,
      messagesByRoom: messagesByRoom ?? this.messagesByRoom,
      selectedRoomJid:
          clearSelectedRoom ? null : (selectedRoomJid ?? this.selectedRoomJid),
      roomEpoch: roomEpoch ?? this.roomEpoch,
      pendingSendById: pendingSendById ?? this.pendingSendById,
      globalLoading: globalLoading ?? this.globalLoading,
      loadingText: loadingText ?? this.loadingText,
      editDraft: clearEditDraft ? null : (editDraft ?? this.editDraft),
      activeThread:
          clearActiveThread ? null : (activeThread ?? this.activeThread),
      jumpWindowByRoom: jumpWindowByRoom ?? this.jumpWindowByRoom,
      jumpTarget: clearJumpTarget ? null : (jumpTarget ?? this.jumpTarget),
    );
  }
}
