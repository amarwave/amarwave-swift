# amarwave-swift

Official Swift SDK for [AmarWave](https://amarwave.io) — native iOS, macOS, watchOS, and tvOS client.

Subscribe to channels, bind to real-time events, and handle presence channels using URLSession WebSocket (iOS 14+ / macOS 11+, zero dependencies).

---

## Requirements

| Platform | Minimum Version |
|----------|----------------|
| iOS      | 14.0           |
| macOS    | 11.0           |
| watchOS  | 7.0            |
| tvOS     | 14.0           |

- Swift 5.9+
- Xcode 15+

---

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies** and enter:

```
https://github.com/amarwave/amarwave-swift
```

Or add to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/amarwave/amarwave-swift", from: "10.1.5"),
],
targets: [
    .target(name: "YourApp", dependencies: ["AmarWave"]),
]
```

---

## Quick Start

```swift
import AmarWave

let aw = AmarWave(
    appKey: "your-app-key",
    configuration: AmarWaveConfiguration(
        wsHost: "your-server.com",
        wsPort: 3001,
        useTLS: false
    )
)

// Subscribe to a public channel
let channel = aw.subscribe(to: "notifications")

channel.bind(event: "new-message") { data in
    if let dict = data as? [String: Any] {
        print("Message:", dict["body"] ?? "")
    }
}
```

---

## Configuration

```swift
let config = AmarWaveConfiguration(
    wsHost: "your-server.com",  // WebSocket server hostname
    wsPort: 3001,               // Plain-text port
    wssPort: 443,               // TLS port
    useTLS: false,              // true = wss://
    authEndpoint: "https://your-api.com/broadcasting/auth",  // for private/presence
    authHeaders: [
        "Authorization": "Bearer \(token)"
    ],
    activityTimeout: 120,       // seconds before sending ping
    reconnectDelay: 1,          // base delay for reconnect (exponential backoff)
    maxReconnectDelay: 30,
    maxRetries: 6,              // 0 = infinite
    pongTimeout: 30
)

let aw = AmarWave(appKey: "your-key", configuration: config)
```

---

## Connection Events

```swift
aw.connection.bind(event: "connected") { _ in
    print("✅ Connected. Socket ID:", aw.connection.socketId ?? "")
}

aw.connection.bind(event: "disconnected") { _ in
    print("⚠️ Disconnected — will retry")
}

aw.connection.bind(event: "failed") { _ in
    print("❌ Max retries reached")
}

aw.connection.bind(event: "state_change") { data in
    if let change = data as? [String: String] {
        print("State:", change["previous"] ?? "", "→", change["current"] ?? "")
    }
}

// Read state directly
print(aw.connection.state)  // .initialized / .connecting / .connected / .disconnected / .failed
```

---

## Public Channels

```swift
let channel = aw.subscribe(to: "orders")

// Raw handler
channel.bind(event: "placed") { data in
    print(data)
}

// Typed Codable handler
struct Order: Decodable {
    let id: Int
    let total: Double
}

channel.bind(event: "placed", as: Order.self) { order in
    print("Order #\(order.id): $\(order.total)")
}

// Bind all events
channel.bindAll { event, data in
    print("[\(event)]", data)
}

// Unsubscribe
aw.unsubscribe(from: "orders")
```

---

## Private Channels

Private channels (`private-`) require server-side authentication.
Set `authEndpoint` in your configuration — the SDK calls it automatically.

```swift
let config = AmarWaveConfiguration(
    wsHost: "your-server.com",
    wsPort: 3001,
    authEndpoint: "https://your-api.com/broadcasting/auth",
    authHeaders: ["Authorization": "Bearer \(userToken)"]
)

let aw = AmarWave(appKey: "your-key", configuration: config)
let privateChannel = aw.subscribe(to: "private-user-\(userId)")

privateChannel.bind(event: "notification") { data in
    print("Private notification:", data)
}
```

**Server-side auth endpoint** (Go example):
```go
func authHandler(w http.ResponseWriter, r *http.Request) {
    socketID    := r.FormValue("socket_id")
    channelName := r.FormValue("channel_name")

    msg := socketID + ":" + channelName
    mac := hmac.New(sha256.New, []byte(appSecret))
    mac.Write([]byte(msg))
    signature := hex.EncodeToString(mac.Sum(nil))

    json.NewEncoder(w).Encode(map[string]string{
        "auth": appKey + ":" + signature,
    })
}
```

---

## Presence Channels

Presence channels (`presence-`) track which users are online.

```swift
let presence = aw.subscribe(to: "presence-lobby") as! AmarWavePresenceChannel

presence.bind(event: "subscription_succeeded") { _ in
    print("Members online:", presence.memberCount)
    print("My info:", presence.me ?? [:])
}

presence.bind(event: "pusher_internal:member_added") { data in
    print("User joined:", data)
    print("Total members:", presence.memberCount)
}

presence.bind(event: "pusher_internal:member_removed") { data in
    print("User left:", data)
}

// Iterate all members
for (userId, info) in presence.members {
    print("User \(userId):", info["name"] ?? "")
}
```

---

## Async/Await Pattern

Wrap callbacks in a `CheckedContinuation`:

```swift
func waitForConnection(_ aw: AmarWave) async {
    if aw.connection.state == .connected { return }
    await withCheckedContinuation { continuation in
        aw.connection.bind(event: "connected") { _ in
            continuation.resume()
        }
    }
}

// Usage in a Task
Task {
    await waitForConnection(aw)
    let channel = aw.subscribe(to: "live-scores")
    channel.bind(event: "score-update") { data in
        DispatchQueue.main.async {
            // update UI
        }
    }
}
```

---

## SwiftUI Integration

```swift
import SwiftUI
import AmarWave

class RealTimeViewModel: ObservableObject {
    @Published var messages: [String] = []

    private let aw: AmarWave

    init() {
        aw = AmarWave(
            appKey: "your-key",
            configuration: AmarWaveConfiguration(wsHost: "your-server.com")
        )

        let channel = aw.subscribe(to: "chat")
        channel.bind(event: "message") { [weak self] data in
            if let dict = data as? [String: Any],
               let body = dict["body"] as? String {
                DispatchQueue.main.async {
                    self?.messages.append(body)
                }
            }
        }
    }

    deinit { aw.disconnect() }
}

struct ChatView: View {
    @StateObject private var vm = RealTimeViewModel()

    var body: some View {
        List(vm.messages, id: \.self) { Text($0) }
    }
}
```

---

## Disconnect

```swift
aw.disconnect()  // closes WebSocket, stops reconnect
```

---

## License

MIT
