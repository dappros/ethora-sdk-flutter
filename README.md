# Ethora SDK Flutter

`ethora-sdk-flutter` is a reusable `chat_component` SDK for Flutter apps.

It mirrors web behavior first and aligns with Android/Swift architecture where web is silent:

- Auth: email/password + JWT login
- API: `/users/login-with-email`, `/users/client`, `/users/login/refresh`
- XMPP (WebSocket-first): connect, global presence, room presence, history, send text/media, typing
- Chat runtime: pending messages, room list/single-room, logs stream

## Package layout

- `lib/chat_component/chat_component.dart`: stable public API
- `lib/src/core`: controller, API/auth/rooms services, XMPP client, store, logs, state
- `lib/src/ui`: built-in chat widget
- `example`: 3-tab integration app (`Home`, `Chat`, `Logs`)

## Quick Start

### 1. Installation

Add the SDK to your `pubspec.yaml`:

```yaml
dependencies:
  ethora_sdk_flutter:
    path: ../ethora-sdk-flutter # Or your preferred installation method
```

### 2. Basic Usage

Import the package and initialize the controller in your widget state:

```dart
import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';

class MyChatPage extends StatefulWidget {
  @override
  _MyChatPageState createState() => _MyChatPageState();
}

class _MyChatPageState extends State<MyChatPage> {
  late final ChatComponentController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ChatComponentController(
      config: const ChatComponentConfig(
        appId: 'YOUR_APP_ID',
        baseUrl: 'https://api.ethoradev.com',
        customAppToken: 'YOUR_JWT_TOKEN', // Optional
        defaultLogin: true, // Auto-login if session exists
        xmppSettings: XmppSettings(
          xmppServerUrl: 'wss://xmpp-dev.preshent.com/ws',
          host: 'xmpp-dev.preshent.com',
          conference: 'conference.xmpp-dev.preshent.com',
        ),
      ),
    );
    
    // Start the SDK
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Chat')),
      body: ChatComponent(
        controller: _controller,
        config: _controller.config,
      ),
    );
  }
}
```

## Running the Example (Test App)

The repository includes a comprehensive example application to test all SDK features.

1.  **Navigate to the example directory:**
    ```bash
    cd example
    ```

2.  **Install dependencies:**
    ```bash
    flutter pub get
    ```

3.  **Run the application:**
    ```bash
    # For Android/iOS/Web/Desktop
    flutter run
    ```

The example app features three tabs:
- **Home**: Environment status and authentication controls.
- **Chat**: The live `ChatComponent` in action.
- **Logs**: Real-time stream of SDK events and debugging info.

## Public API

`ChatComponentController` provides full control over the chat lifecycle:

- `initialize()`: Starts the connection and authentication flow.
- `loginEmail(email, password)`: Manual email/password login.
- `loginJwt(token)`: Manual JWT token login.
- `logout()`: Clears the session and disconnects.
- `selectRoom(roomJid)`: Navigates to a specific room.
- `sendText(roomJid, text)`: Sends a message.
- `sendMedia(roomJid, bytes, filename, mimeType)`: Sends an attachment.
- `setTyping(roomJid, isTyping)`: Updates typing status.
- `loadHistory(roomJid, max, beforeId)`: Fetches older messages.

### Reactive State

- `controller.state`: A `ValueNotifier<ChatComponentState>` for UI updates.
- `controller.logs`: A `Stream<ChatLogEvent>` for monitoring SDK activity.

## Configuration Options

`ChatComponentConfig` allows deep customization:

- `appId`, `baseUrl`: Core environment settings.
- `xmppSettings`: WebSocket and XMPP server configuration.
- `disableRooms`: If true, hides the room list and shows a single room view.
- `refreshTokens`: Auto-refresh logic for JWT tokens.
- `chatHeaderSettings`: Customize the appearance of the chat header.
- `disableTypingIndicator`: Toggle typing status visibility.

