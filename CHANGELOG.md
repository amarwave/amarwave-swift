# Changelog

All notable changes to the AmarWave Swift SDK will be documented in this file.

## 1.0.0

- Initial stable release.
- Native URLSession WebSocket — zero external dependencies.
- iOS 14+ / macOS 11+ / watchOS 7+ / tvOS 14+.
- Public, private (`private-`), and presence (`presence-`) channel support.
- `AmarWavePresenceChannel` with live `members` dict, `memberCount`, and `me`.
- `channel.publish(event:data:completion:)` with pre-subscription queue.
- Named cluster support (`cluster: "default"` / `"eu"` etc.) — auto-resolves host and port.
- Client-side HMAC-SHA256 auth via `appSecret` (dev/testing only).
- Server-side channel auth via `authEndpoint`.
- Exponential-backoff reconnect with configurable `maxRetries`.
- Ping/pong keepalive with `activityTimeout` and `pongTimeout`.
- Thread-safe with `NSLock` throughout.
- `AmarWaveConnection` proxy with `bind(event:handler:)` for lifecycle events.
- `bind<T: Decodable>(event:as:handler:)` for type-safe event decoding.
