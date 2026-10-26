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
        baseUrl: 'https://api.chat.ethora.com',
        customAppToken: 'YOUR_JWT_TOKEN', // Optional
        defaultLogin: true, // Auto-login if session exists
        xmppSettings: XmppSettings(
          xmppServerUrl: 'wss://xmpp.chat.ethora.com/ws',
          host: 'xmpp.chat.ethora.com',
          conference: 'conference.xmpp.chat.ethora.com',
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


## Calls

1:1 and group audio/video calls, matching the web SDK. Off by default. Public rooms
never call.

```dart
final config = ChatComponentConfig(
  // ...
  videoCalls: const VideoCallsConfig(
    enabled: true,
    livekitUrl: 'wss://livekit.example.com',
    enableAudioCalls: true,
    // allowedRoomTypes: [CallRoomType.private], // 1:1 only
    // startWithCameraOn: false, startWithMicOn: false,
    // showScreenShare: true,   // LiveKit video calls, see "Screen sharing"
    // ringtone: false,         // no in-app ringtone / ringback
    // nativeCallUi: false,     // no CallKit / full-screen call notification
  ),
);
```

- Wrap your chat UI once in `CallOverlayHost(controller: ..., config: ..., child: ...)`.
  It rings for incoming calls on any screen and shows the outgoing, active (local and
  remote video, mute, camera, flip, speaker, end) and error screens. A group call shows
  everyone in a grid that fills the screen, outlines whoever is speaking, and scrolls
  when the tiles would get too small.
- Put `CallHeaderButtons(controller: ..., config: ..., room: room)` in a chat header to
  get the video (and, with `enableAudioCalls`, audio) call buttons. It renders nothing
  when calls are off or the room type is not allowed.
- The server picks the transport per call: 1:1 chats use peer to peer WebRTC (TURN/STUN
  from the backend) when it is enabled there, otherwise LiveKit; group chats always use
  LiveKit. `controller.calls` exposes the state (`CallsCoordinator`) for custom UI.
- Call log entries arrive as system messages (`data['type'] == 'call-state'`). Use
  `CallLogInfo.fromMessage(message, selfXmppUsername: ...)?.label(strings)` to render
  "Outgoing call · 12 sec", "Missed call" or "No answer". When a call ends the SDK also
  adds its own entry to the room (in case the server's never arrives); the two are
  merged by call id, so there is never a double.

### Sounds

The caller hears a ringback tone and the callee a ringtone while the app is in the
foreground. They are two small synthesised loops in `assets/calls/` (regenerate with
`python3 tool/generate_call_tones.py`), played with `audioplayers`, so they sound the same
on every device. When the app is in the background the system ringtone of the native call
UI rings instead (below).

### Incoming calls when the app is in the background or closed

`flutter_callkit_incoming` shows CallKit on iOS and a full-screen call notification
(over the lock screen, with the system ringtone) on Android. The SDK uses it for:

- an XMPP call that rings while the app is not in the foreground;
- a call push: call `ChatCallKit.showIncomingFromPush(data)` from your background push
  handler. Then accept and decline on that UI work even after a cold start, and the
  accept joins the call.
- a call push tapped as a normal notification: `controller.handlePushPayload(data)` rings
  it in-app (the SDK installs `controller.onCallPush` unless you set your own).

```dart
@pragma('vm:entry-point')
Future<void> onBackgroundMessage(RemoteMessage message) async {
  await ChatCallKit.showIncomingFromPush(message.data); // false: not a call push
}
```

The call push payload (RN spec section 9/10): `type`/`pushType` = `call`, `callId`,
`callToken`/`livekitToken`/`token`, `callKind`/`kind`, `callRoom`/`room`, `callerName`,
`callerXmppUsername`, `mode` (`p2p` or `livekit`), `group`. A LiveKit join token lives about
a minute, so a LiveKit call can only be answered within that time; a p2p call has no token
and the caller keeps re-sending its offer until it is answered.

Call `ChatCallKit.requestPermissions()` once (Android 13+ notifications, Android 14+
full-screen intent). On iOS, VoIP pushes need the PushKit setup of
`flutter_callkit_incoming` (its `PUSHKIT.md`) in `AppDelegate.swift`; register the token
with `controller.registerPushToken(await ChatCallKit.voipPushToken(), tokenType:
PushTokenType.apnsVoip)`. A VoIP push must be reported to CallKit the moment it arrives,
which is what `showIncomingFromPush` does.

### Ongoing calls in the background

- Android: the same plugin runs the ongoing-call foreground service (types
  `phoneCall|microphone|camera`) with a "Hang up" notification button, started when a call
  is being set up, so the microphone and camera survive the home screen on Android 14+.
- iOS: add the `audio` background mode (below). The camera stops in the background; audio
  continues.

### Screen sharing

Web shares the screen in LiveKit calls, so `showScreenShare: true` adds a share button to
LiveKit video calls (not to p2p calls, like web). It is off by default because a phone
needs extra native setup:

- Android: the `mediaProjection` foreground service declaration and permission below.
  The SDK asks for the capture permission, then starts that service with
  `flutter_foreground_task`.
- iOS: sharing the app's own screen works as is. Sharing other apps needs a broadcast
  upload extension (see the flutter-webrtc "iOS Screen Sharing" wiki).

A remote screen share fills the stage (and the group grid moves to a strip beneath it).

### Platform setup

The SDK cannot add these for you.

iOS `Info.plist` (see `example/ios/Runner/Info.plist`); deployment target iOS 13:

```xml
<key>NSCameraUsageDescription</key>
<string>The camera is used for video calls.</string>
<key>NSMicrophoneUsageDescription</key>
<string>The microphone is used for calls.</string>
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
  <!-- Only if you use PushKit VoIP pushes with CallKit: -->
  <string>voip</string>
  <string>remote-notification</string>
</array>
```

Android `android/app/src/main/AndroidManifest.xml` (see
`example/android/app/src/main/AndroidManifest.xml`):

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_PHONE_CALL" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CAMERA" />
<uses-permission android:name="android.permission.MANAGE_OWN_CALLS" />
<!-- only with showScreenShare: -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION" />

<application ...>
  <!-- flutter_callkit_incoming needs the main activity as a single instance -->
  <activity android:name=".MainActivity" android:launchMode="singleInstance" ...>
  ...
  <!-- only with showScreenShare: -->
  <service
      android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
      android:foregroundServiceType="mediaProjection"
      android:exported="false" />
</application>
```

Also: `minSdkVersion` 23 or higher and Java 17 (`flutter_callkit_incoming` 2.5+); add
`-keep class com.hiennv.flutter_callkit_incoming.** { *; }` to `proguard-rules.pro` if you
minify; request `BLUETOOTH_CONNECT` at runtime for Bluetooth headsets on Android 12+.
