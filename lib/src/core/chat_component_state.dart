import '../models/chat_message.dart';
import '../models/chat_room.dart';
import '../models/chat_user.dart';

enum ChatConnectionState { offline, connecting, online, error }

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
      selectedRoomJid: selectedRoomJid ?? this.selectedRoomJid,
    );
  }
}
