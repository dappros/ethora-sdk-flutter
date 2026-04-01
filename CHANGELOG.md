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
