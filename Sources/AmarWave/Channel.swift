import Foundation

// MARK: - AmarWaveChannel

/// Represents a subscription to an AmarWave channel.
///
/// Obtain a channel by calling `aw.subscribe(to: "channel-name")`.
/// Then bind event handlers on it:
///
/// ```swift
/// let ch = aw.subscribe(to: "orders")
///
/// // Typed handler via Codable
/// ch.bind(event: "placed", as: Order.self) { order in
///     print("New order:", order.id)
/// }
///
/// // Raw handler
/// ch.bind(event: "updated") { data in
///     print("Raw data:", data)
/// }
/// ```
open class AmarWaveChannel: NSObject {

    /// The channel name, e.g. `"chat"`, `"private-user-42"`, `"presence-lobby"`.
    public let name: String

    /// Whether the server has confirmed the subscription.
    public private(set) var isSubscribed: Bool = false

    // MARK: - Internal storage

    private var handlers: [String: [(Any) -> Void]] = [:]
    private var globalHandlers: [(String, Any) -> Void] = []
    private let lock = NSLock()

    // MARK: - Publish support

    /// Closure type used to perform the actual HTTP publish.
    typealias PublishFn = (_ event: String, _ data: [String: Any], _ completion: ((Bool) -> Void)?) -> Void

    private var _publishFn: PublishFn?

    private struct QueuedPublish {
        let event: String
        let data: [String: Any]
        let completion: ((Bool) -> Void)?
    }

    private var _publishQueue: [QueuedPublish] = []
    private let queueLock = NSLock()

    // MARK: - Init

    init(name: String, publish: PublishFn? = nil) {
        self.name = name
        self._publishFn = publish
        super.init()
    }

    // MARK: - Binding

    /// Bind a closure to a specific event name.
    ///
    /// Multiple bindings for the same event are all invoked (in registration order).
    ///
    /// - Parameters:
    ///   - event: The event name emitted by the server, e.g. `"order-placed"`.
    ///   - handler: Closure called with the decoded event data (`Any`, usually a `[String: Any]`).
    /// - Returns: `self` for chaining.
    @discardableResult
    public func bind(event: String, handler: @escaping (Any) -> Void) -> Self {
        lock.lock()
        handlers[event, default: []].append(handler)
        lock.unlock()
        return self
    }

    /// Bind a `Decodable` typed handler to a specific event.
    ///
    /// The event data is expected to be a JSON object that decodes into `T`.
    ///
    /// ```swift
    /// channel.bind(event: "placed", as: Order.self) { order in
    ///     print(order.id)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - event: Event name.
    ///   - type: The `Decodable` type to decode the data into.
    ///   - handler: Closure receiving a decoded value of type `T`.
    /// - Returns: `self` for chaining.
    @discardableResult
    public func bind<T: Decodable>(event: String, as type: T.Type, handler: @escaping (T) -> Void) -> Self {
        return bind(event: event) { data in
            do {
                let jsonData: Data
                if let dict = data as? [String: Any] {
                    jsonData = try JSONSerialization.data(withJSONObject: dict)
                } else if let existing = data as? Data {
                    jsonData = existing
                } else {
                    return
                }
                let decoded = try JSONDecoder().decode(type, from: jsonData)
                handler(decoded)
            } catch {
                print("[AmarWave] Failed to decode event '\(event)' as \(type): \(error)")
            }
        }
    }

    /// Bind a handler that fires for **every** event on this channel.
    ///
    /// - Parameter handler: Closure receiving the event name and data.
    /// - Returns: `self` for chaining.
    @discardableResult
    public func bindAll(handler: @escaping (_ event: String, _ data: Any) -> Void) -> Self {
        lock.lock()
        globalHandlers.append(handler)
        lock.unlock()
        return self
    }

    /// Remove all handlers for a specific event.
    ///
    /// - Parameter event: The event name to remove handlers for.
    @discardableResult
    public func unbind(event: String) -> Self {
        lock.lock()
        handlers.removeValue(forKey: event)
        lock.unlock()
        return self
    }

    /// Remove all event handlers (specific and global) from this channel.
    @discardableResult
    public func unbindAll() -> Self {
        lock.lock()
        handlers.removeAll()
        globalHandlers.removeAll()
        lock.unlock()
        return self
    }

    // MARK: - Publish

    /// Publish an event to this channel via the HTTP API.
    ///
    /// Safe to call before `isSubscribed` is true — calls are queued and flushed
    /// automatically once the subscription is confirmed.
    ///
    /// - Parameters:
    ///   - event:      Event name subscribers will receive.
    ///   - data:       JSON-serialisable dictionary. Defaults to `[:]`.
    ///   - completion: Called with `true` on success, `false` on error.
    ///
    /// ```swift
    /// channel.publish(event: "message", data: ["user": "Ali", "text": "Hello!"])
    /// ```
    public func publish(
        event: String,
        data: [String: Any] = [:],
        completion: ((Bool) -> Void)? = nil
    ) {
        if !isSubscribed {
            queueLock.lock()
            _publishQueue.append(QueuedPublish(event: event, data: data, completion: completion))
            queueLock.unlock()
            return
        }
        _publishFn?(event, data, completion) ?? completion?(false)
    }

    /// Alias for `publish`. Kept for compatibility.
    @discardableResult
    public func trigger(
        event: String,
        data: [String: Any] = [:],
        completion: ((Bool) -> Void)? = nil
    ) -> Self {
        publish(event: event, data: data, completion: completion)
        return self
    }

    // MARK: - Internal

    func setSubscribed(_ value: Bool) {
        isSubscribed = value
    }

    /// Flush any publishes queued before subscription was confirmed.
    func flushQueue() {
        queueLock.lock()
        let items = _publishQueue
        _publishQueue.removeAll()
        queueLock.unlock()
        for item in items {
            _publishFn?(item.event, item.data, item.completion) ?? item.completion?(false)
        }
    }

    func handleEvent(_ event: String, data: Any) {
        lock.lock()
        let eventHandlers = handlers[event] ?? []
        let globals = globalHandlers
        lock.unlock()

        eventHandlers.forEach { $0(data) }
        globals.forEach { $0(event, data) }
    }
}

// MARK: - AmarWavePresenceChannel

/// A presence channel that tracks which members are currently subscribed.
///
/// ```swift
/// let presence = aw.subscribe(to: "presence-lobby") as! AmarWavePresenceChannel
///
/// presence.bind(event: "member_added") { _ in
///     print("Members:", presence.memberCount)
/// }
/// ```
public final class AmarWavePresenceChannel: AmarWaveChannel {

    /// All currently subscribed members, keyed by their `user_id`.
    public private(set) var members: [String: [String: Any]] = [:]

    /// The current user's presence data (set when subscription is confirmed).
    public private(set) var me: [String: Any]?

    /// Number of members currently subscribed to this channel.
    public var memberCount: Int { members.count }

    private let membersLock = NSLock()

    // MARK: - Internal

    override func handleEvent(_ event: String, data: Any) {
        switch event {
        case "amarwave_internal:subscription_succeeded", "subscribed":
            // Server sends presence data: { "presence": { "count": N, "ids": [...], "hash": {...} } }
            if let dict = data as? [String: Any],
               let presence = dict["presence"] as? [String: Any],
               let hash = presence["hash"] as? [String: [String: Any]] {
                membersLock.lock()
                members = hash
                membersLock.unlock()
            }

        case "amarwave_internal:member_added":
            // { "user_id": "42", "user_info": { "name": "Alice" } }
            if let dict = data as? [String: Any],
               let userId = dict["user_id"] as? String {
                let info = dict["user_info"] as? [String: Any] ?? [:]
                membersLock.lock()
                members[userId] = info
                membersLock.unlock()
            }

        case "amarwave_internal:member_removed":
            // { "user_id": "42" }
            if let dict = data as? [String: Any],
               let userId = dict["user_id"] as? String {
                membersLock.lock()
                members.removeValue(forKey: userId)
                membersLock.unlock()
            }

        default:
            break
        }

        // Always forward to user-registered handlers
        super.handleEvent(event, data: data)
    }
}
