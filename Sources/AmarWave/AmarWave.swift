import CryptoKit
import Foundation

// MARK: - Configuration

/// Configuration for the AmarWave WebSocket client.
public struct AmarWaveConfiguration {
    /// Hostname of the AmarWave WebSocket server.
    public var wsHost: String
    /// Plain-text WebSocket port (used when `useTLS` is false).
    public var wsPort: Int
    /// Secure WebSocket port (used when `useTLS` is true).
    public var wssPort: Int
    /// Whether to connect with `wss://` and TLS.
    public var useTLS: Bool

    /// HTTP API hostname for publishing events. Defaults to `wsHost` when `nil`.
    public var apiHost: String?
    /// HTTP API port. Used by `publish()`. Default: 8000.
    public var apiPort: Int
    /// HTTP API trigger path. Default: "/api/v1/trigger".
    public var apiPath: String
    /// WebSocket upgrade path. Default: "/ws".
    public var wsPath: String

    /// Your AmarWave app secret. Enables client-side HMAC auth for
    /// private/presence channels — no `authEndpoint` needed.
    /// ⚠️  Do **not** ship in production apps; use `authEndpoint` instead.
    public var appSecret: String?
    /// URL of your server-side channel authentication endpoint.
    /// Required for private/presence channels when `appSecret` is nil.
    public var authEndpoint: String?
    /// Extra HTTP headers to send with authentication requests.
    public var authHeaders: [String: String]

    /// Seconds of inactivity before sending a ping. Default: 120.
    public var activityTimeout: TimeInterval
    /// Base reconnect delay in seconds (exponential backoff). Default: 1.
    public var reconnectDelay: TimeInterval
    /// Maximum reconnect delay in seconds. Default: 30.
    public var maxReconnectDelay: TimeInterval
    /// Maximum number of reconnect attempts before entering `.failed` state.
    /// Set to 0 for infinite retries.
    public var maxRetries: Int
    /// Seconds to wait for a pong response before closing. Default: 30.
    public var pongTimeout: TimeInterval
    /// Disable usage stats in ping payloads. Default: false.
    public var disableStats: Bool

    /// Resolved API host — falls back to `wsHost` when `apiHost` is nil.
    var resolvedApiHost: String { apiHost ?? wsHost }

    /// Supported environment variables:
    /// - `AMARWAVE_WS_HOST`       WebSocket hostname          (default: localhost)
    /// - `AMARWAVE_WS_PORT`       WebSocket plain-text port   (default: 3001)
    /// - `AMARWAVE_WSS_PORT`      WebSocket TLS port           (default: 443)
    /// - `AMARWAVE_WS_TLS`        'true' to enable TLS        (default: false)
    /// - `AMARWAVE_WS_PATH`       WebSocket upgrade path       (default: /ws)
    /// - `AMARWAVE_API_HOST`      HTTP API hostname            (default: wsHost)
    /// - `AMARWAVE_API_PORT`      HTTP API port                (default: 8000)
    /// - `AMARWAVE_API_PATH`      HTTP API trigger path        (default: /api/v1/trigger)
    /// - `AMARWAVE_APP_SECRET`    App secret for HMAC auth    (default: nil)
    /// - `AMARWAVE_AUTH_ENDPOINT` Channel auth endpoint URL   (default: nil)
    public init(
        wsHost: String? = nil,
        wsPort: Int? = nil,
        wssPort: Int = 443,
        useTLS: Bool? = nil,
        wsPath: String? = nil,
        apiHost: String? = nil,
        apiPort: Int = 8000,
        apiPath: String? = nil,
        appSecret: String? = nil,
        authEndpoint: String? = nil,
        authHeaders: [String: String] = [:],
        activityTimeout: TimeInterval = 120,
        reconnectDelay: TimeInterval = 1,
        maxReconnectDelay: TimeInterval = 30,
        maxRetries: Int = 6,
        pongTimeout: TimeInterval = 30,
        disableStats: Bool = false
    ) {
        let env = ProcessInfo.processInfo.environment
        self.wsHost            = wsHost     ?? env["AMARWAVE_WS_HOST"]  ?? "localhost"
        self.wsPort            = wsPort     ?? env["AMARWAVE_WS_PORT"].flatMap(Int.init) ?? 3001
        self.wssPort           = env["AMARWAVE_WSS_PORT"].flatMap(Int.init) ?? wssPort
        self.useTLS            = useTLS     ?? (env["AMARWAVE_WS_TLS"]?.lowercased() == "true")
        self.wsPath            = wsPath     ?? env["AMARWAVE_WS_PATH"]  ?? "/ws"
        self.apiHost           = apiHost    ?? env["AMARWAVE_API_HOST"]
        self.apiPort           = env["AMARWAVE_API_PORT"].flatMap(Int.init) ?? apiPort
        self.apiPath           = apiPath    ?? env["AMARWAVE_API_PATH"] ?? "/api/v1/trigger"
        self.appSecret         = appSecret  ?? env["AMARWAVE_APP_SECRET"]
        self.authEndpoint      = authEndpoint ?? env["AMARWAVE_AUTH_ENDPOINT"]
        self.authHeaders       = authHeaders
        self.activityTimeout   = activityTimeout
        self.reconnectDelay    = reconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
        self.maxRetries        = maxRetries
        self.pongTimeout       = pongTimeout
        self.disableStats      = disableStats
    }
}

// MARK: - Connection State

/// The current lifecycle state of the WebSocket connection.
public enum ConnectionState: String, Sendable {
    case initialized
    case connecting
    case connected
    case disconnected
    case failed
}

// MARK: - AmarWave (Main Client)

/// Main AmarWave client. Manages the WebSocket connection and channel subscriptions.
///
/// Example:
/// ```swift
/// let aw = AmarWave(
///     appKey: "your-app-key",
///     appSecret: "your-app-secret",   // optional — enables client-side HMAC
///     configuration: AmarWaveConfiguration(wsHost: "your-server.com")
/// )
///
/// aw.connection.bind(event: "connected") { _ in
///     print("Connected! Socket ID:", aw.connection.socketId ?? "")
/// }
///
/// let channel = aw.subscribe(to: "public-chat")
/// channel.bind(event: "message") { data in
///     if let dict = data as? [String: Any] { print("Message:", dict) }
/// }
/// ```
public class AmarWave: NSObject {

    /// Exposes connection state and lifecycle events.
    public let connection: AmarWaveConnection

    private let appKey: String
    private let config: AmarWaveConfiguration
    private var channels: [String: AmarWaveChannel] = [:]
    private let lock = NSLock()

    // MARK: - Init

    /// Create a new AmarWave client and immediately begin connecting.
    ///
    /// - Parameters:
    ///   - appKey: Your AmarWave application key.
    ///   - appSecret: Optional shorthand — enables client-side HMAC auth for
    ///     private/presence channels (same as `configuration.appSecret`).
    ///   - configuration: Full configuration. All fields have sensible defaults.
    public init(
        appKey: String,
        appSecret: String? = nil,
        configuration: AmarWaveConfiguration = AmarWaveConfiguration()
    ) {
        precondition(!appKey.isEmpty, "AmarWave: appKey must not be empty.")
        var cfg = configuration
        if let s = appSecret, cfg.appSecret == nil { cfg.appSecret = s }

        self.appKey     = appKey
        self.config     = cfg
        self.connection = AmarWaveConnection(appKey: appKey, configuration: cfg)
        super.init()

        connection.onMessage = { [weak self] event, channelName, data in
            guard let self else { return }
            self.handleMessage(event: event, channelName: channelName, data: data)
        }
        connection.onReconnected = { [weak self] in
            self?.resubscribeAll()
        }
        connection.connect()
    }

    // MARK: - Public API

    /// Subscribe to a channel and return the channel object.
    ///
    /// If the subscription already exists, the existing channel is returned.
    ///
    /// - Parameter channelName: e.g. `"chat-room-1"`, `"private-orders"`,
    ///   or `"presence-lobby"`.
    @discardableResult
    public func subscribe(to channelName: String) -> AmarWaveChannel {
        lock.lock()
        if let existing = channels[channelName] {
            lock.unlock()
            return existing
        }

        let channel: AmarWaveChannel = channelName.hasPrefix("presence-")
            ? AmarWavePresenceChannel(name: channelName)
            : AmarWaveChannel(name: channelName)

        channels[channelName] = channel
        lock.unlock()

        sendSubscribe(channel: channel)
        return channel
    }

    /// Unsubscribe from a channel and remove it from the client.
    public func unsubscribe(from channelName: String) {
        lock.lock()
        let removed = channels.removeValue(forKey: channelName)
        lock.unlock()

        guard removed != nil else { return }
        connection.send([
            "event": "amarwave:unsubscribe",
            "data": ["channel": channelName],
        ])
    }

    /// Return an existing channel object without subscribing. `nil` if not found.
    public func channel(_ name: String) -> AmarWaveChannel? {
        lock.lock(); defer { lock.unlock() }
        return channels[name]
    }

    /// Disconnect the WebSocket and stop all reconnect attempts.
    public func disconnect() {
        connection.disconnect()
    }

    /// Publish an event to a channel via the HTTP API.
    ///
    /// - Parameters:
    ///   - channel:    Channel name.
    ///   - event:      Event name subscribers will receive.
    ///   - data:       JSON-serialisable dictionary. Defaults to `[:]`.
    ///   - completion: Called on completion with `true` on success, `false` on error.
    /// - Returns: The underlying `URLSessionDataTask` (already resumed).
    @discardableResult
    public func publish(
        channel: String,
        event: String,
        data: [String: Any] = [:],
        completion: ((Bool) -> Void)? = nil
    ) -> URLSessionDataTask? {
        let scheme = config.useTLS ? "https" : "http"
        let urlStr = "\(scheme)://\(config.resolvedApiHost):\(config.apiPort)\(config.apiPath)"
        guard let url = URL(string: urlStr) else {
            completion?(false); return nil
        }

        var req        = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "app_key":    appKey,
            "app_secret": config.appSecret ?? "",
            "channel":    channel,
            "name":       event,
            "data":       data,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion?(false); return nil
        }
        req.httpBody = bodyData

        let task = URLSession.shared.dataTask(with: req) { _, response, error in
            if let error {
                print("[AmarWave] publish error: \(error.localizedDescription)")
                completion?(false); return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok     = (200..<300).contains(status)
            if !ok { print("[AmarWave] publish failed: HTTP \(status)") }
            completion?(ok)
        }
        task.resume()
        return task
    }

    // MARK: - Internal

    private func sendSubscribe(channel: AmarWaveChannel) {
        guard connection.state == .connected else { return }
        let name = channel.name

        if name.hasPrefix("presence-") {
            if let secret = config.appSecret, !secret.isEmpty {
                // Client-side HMAC for presence
                let userId = UUID().uuidString
                let cdMap: [String: Any] = ["user_id": userId, "user_info": [:] as [String: Any]]
                guard let cdData = try? JSONSerialization.data(withJSONObject: cdMap),
                      let cdStr  = String(data: cdData, encoding: .utf8) else { return }
                let sig = hmacSHA256(key: secret, message: "\(connection.socketId ?? ""):\(name):\(cdStr)")
                connection.send([
                    "event": "amarwave:subscribe",
                    "data": ["channel": name, "auth": "\(appKey):\(sig)", "channel_data": cdStr],
                ])
            } else {
                authenticateViaEndpoint(channel: channel)
            }
        } else if name.hasPrefix("private-") {
            if let secret = config.appSecret, !secret.isEmpty {
                // Client-side HMAC for private
                let sig = hmacSHA256(key: secret, message: "\(connection.socketId ?? ""):\(name)")
                connection.send([
                    "event": "amarwave:subscribe",
                    "data": ["channel": name, "auth": "\(appKey):\(sig)"],
                ])
            } else {
                authenticateViaEndpoint(channel: channel)
            }
        } else {
            connection.send([
                "event": "amarwave:subscribe",
                "data": ["channel": name],
            ])
        }
    }

    private func authenticateViaEndpoint(channel: AmarWaveChannel) {
        guard let socketId = connection.socketId else { return }
        guard let endpoint = config.authEndpoint,
              let url = URL(string: endpoint) else {
            print("[AmarWave] authEndpoint is not configured. Cannot subscribe to \(channel.name).")
            return
        }

        var req        = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in config.authHeaders { req.setValue(v, forHTTPHeaderField: k) }

        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "socket_id",    value: socketId),
            URLQueryItem(name: "channel_name", value: channel.name),
        ]
        req.httpBody = comps.query?.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                print("[AmarWave] Auth failed for \(channel.name): \(error.localizedDescription)")
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let auth = json["auth"] as? String else {
                print("[AmarWave] Auth response for \(channel.name) was invalid.")
                return
            }
            var subData: [String: Any] = ["channel": channel.name, "auth": auth]
            if let cd = json["channel_data"] as? String { subData["channel_data"] = cd }
            self.connection.send(["event": "amarwave:subscribe", "data": subData])
        }.resume()
    }

    private func handleMessage(event: String, channelName: String?, data: Any) {
        guard let channelName else { return }
        lock.lock()
        let channel = channels[channelName]
        lock.unlock()

        switch event {
        case "amarwave_internal:subscription_succeeded":
            channel?.setSubscribed(true)
            channel?.handleEvent("subscribed", data: data)
            channel?.handleEvent("amarwave_internal:subscription_succeeded", data: data)
        case "amarwave_internal:member_added":
            (channel as? AmarWavePresenceChannel)?.handleEvent(event, data: data)
        case "amarwave_internal:member_removed":
            (channel as? AmarWavePresenceChannel)?.handleEvent(event, data: data)
        default:
            channel?.handleEvent(event, data: data)
        }
    }

    private func resubscribeAll() {
        lock.lock()
        let all = Array(channels.values)
        lock.unlock()
        all.forEach { ch in ch.setSubscribed(false); sendSubscribe(channel: ch) }
    }

    // MARK: - HMAC-SHA256

    private func hmacSHA256(key: String, message: String) -> String {
        let symKey = SymmetricKey(data: Data(key.utf8))
        let mac    = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symKey)
        return mac.map { String(format: "%02hhx", $0) }.joined()
    }
}
