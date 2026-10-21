# Changelog

## 0.1.0

- Initial Flutter package scaffold.
- Added parity-focused config model based on web `IConfig`.
- Added startup/login precedence logic aligned with Swift/Kotlin behavior.
- Added cache-first + API-refresh room loading flow.
- Added integration docs and runnable example.

## 0.2.0

- Rebuilt SDK around `chat_component` module architecture.
- Added production-oriented `ChatComponentController` with explicit lifecycle/actions.
- Implemented email/password and JWT auth against Ethora API endpoints.
- Implemented token refresh flow using `/users/login/refresh` with single-flight retries.
- Added WebSocket-first XMPP runtime with presence, history requests, typing, and send text/media.
- Added pending message reconciliation and room-mode behavior (`disableRooms`).
- Replaced example app with `Home` / `Chat` / `Logs` tabs.
- Added tests for config normalization, API behavior, auth/login-required behavior, and typing/pending flows.

## Unreleased (web parity port)

- XMPP runtime rebuilt like web: SASL auth with resource bind, web stanza parser (edit, delete, reactions, receipts, typing, MUC-SUB wrapper), MAM cursors from the archive id with `<fin>`, de-duplication, ack by `xmppId`, watchdog (text 10 s, media 30 s) with tap to retry, secure credential storage.
- Messaging: emoji reactions (quick bar, full picker, chips, reactor names), reply threads with a thread panel and "Also send to room", edit and delete with the web menu rules, delivery and read ticks (XEP-0184, XEP-0333) with the `receipts` policy, typing with expiry.
- Media: multi-file messages (`attachments`, up to 10), album grid, viewer, secure file URLs with the `ft` token, captions.
- Search and jump to message, room list swipe actions (mute, report, leave), public chats directory, member management, `ethora-event` and MUC membership handling.
- Theme and i18n: light, dark or system scheme, typography, tablet split layout, six built-in languages with host overrides, message translations (auto and manual).
- Account: refresh-token rotation with the web error-code table, proactive refresh, host `refreshFunction`, XMPP credential recovery, language, change password, export and delete account, ordered logout.
- Push registration API (the host passes the token), MucSub subscriptions, push payload handling.
- Audio and video calls over LiveKit and P2P WebRTC, off by default (`videoCalls`).
