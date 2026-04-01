# Parity Notes: Web -> Swift/Kotlin -> Flutter

This document tracks what was implemented in the Flutter package and how it maps to existing SDK behavior.

## Source of Truth

Primary config source:

- `ethora-chat-component/src/types/models/config.model.ts` (`IConfig`)

Cross-check implementations:

- Swift: `ethora-sdk-swift/Sources/XMPPChatCore/Models/ChatConfig.swift`
- Swift store behavior: `ethora-sdk-swift/Sources/XMPPChatCore/Store/ConfigStore.swift`
- Kotlin config: `ethora-sdk-android/chat-core/src/main/java/com/ethora/chat/core/config/ChatConfig.kt`
- Kotlin startup flow: `ethora-sdk-android/chat-ui/src/main/java/com/ethora/chat/EthoraChat.kt`

## Implemented in Flutter

### Config model parity

Implemented in:

- `lib/src/config/chat_config.dart`

Included high-value fields used across web/native:

- API/XMPP: `appId`, `baseUrl`, `customAppToken`, `xmppSettings`
- Auth: `jwtLogin`, `userLogin`, `customLogin`, `defaultLogin`
- Feature toggles: `disableRooms`, `disableTypingIndicator`, `disableRoomConfig`, `disableNewChatButton`, etc.
- Header behavior: `chatHeaderSettings`

### Startup/login precedence parity

Implemented in:

- `lib/src/core/chat_controller.dart` (`_resolveUser`)

Order:

1. direct user input (`initialUser`)
2. `config.userLogin` if enabled
3. `config.jwtLogin` if enabled
4. persisted user from store
5. `config.customLogin` if enabled
6. persisted JWT token
7. `loginRequired` or `error`

This mirrors Kotlin startup priorities and is compatible with Swift config-store integration.

### Room loading parity

Implemented in:

- `lib/src/core/chat_controller.dart` (`initialize`)

Flow:

1. read cached rooms from store
2. always refresh rooms from API
3. persist fresh rooms

This matches the Kotlin cache-first + refresh behavior.

## Integration Boundary

API/storage/XMPP-specific logic is intentionally adapter-based:

- `EthoraAuthApi`
- `EthoraRoomsApi`
- `EthoraTokenStore`
- `EthoraUserStore`
- `EthoraRoomStore`

See `lib/src/core/chat_interfaces.dart`.
