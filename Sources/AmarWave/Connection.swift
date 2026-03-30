import Foundation

// MARK: - AmarWaveConnection

/// Manages the WebSocket lifecycle for an AmarWave client.
///
/// Handles connecting, ping/pong keep-alive, and exponential-backoff reconnects.
/// You typically don't use this class directly — interact with it through
/// `AmarWave.connection` to observe state changes.
///
/// ```swift
/// aw.connection.bind(event: "connected") { _ in
///     print("Socket ID:", aw.connection.socketId ?? "?")
/// }
/// aw.connection.bind(event: "disconnected") { _ in
///     print("Disconnected — retrying…")
/// }
/// ```
public final class AmarWaveConnection: NSObject, URLSessionWebSocketDelegate {

    // MARK: - Public State

    /// Current lifecycle state of the connection.
    public private(set) var state: ConnectionState = .initialized {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
            fireHandlers(event: state.rawValue, data: state.rawValue)
            fireHandlers(event: "state_change", data: ["previous": oldValue.rawValue, "current": state.rawValue])
        }
    }

    /// The socket ID assigned by the server after a successful connection.
    public private(set) var socketId: String?

    // MARK: - Internal Callbacks (used by AmarWave)

    var onMessage: ((String, String?, Any) -> Void)?
    var onReconnected: (() -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?

    // MARK: - Private

    private let appKey: String
    private let config: AmarWaveConfiguration

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private var pingTimer: Timer?
    private var pongTimer: Timer?
    private var reconnectTimer: Timer?

    private var retryCount: Int = 0
    private var isDisconnectedIntentionally: Bool = false

    private var eventHandlers: [String: [(Any) -> Void]] = [:]
    private let lock = NSLock()

    // MARK: - Init

    init(appKey: String, configuration: AmarWaveConfiguration) {
        self.appKey = appKey
        self.config = configuration
        super.init()
    }

    // MARK: - Public API

    /// Bind a closure to a connection lifecycle event.
    ///
    /// Supported events: `"connected"`, `"disconnected"`, `"connecting"`,
    /// `"failed"`, `"error"`, `"state_change"`.
    ///
    /// - Parameters:
    ///   - event: Event name.
    ///   - handler: Closure called with event-specific data.
    /// - Returns: `self` for chaining.
    @discardableResult
    public func bind(event: String, handler: @escaping (Any) -> Void) -> Self {
        lock.lock()
        eventHandlers[event, default: []].append(handler)
        lock.unlock()
        return self
    }

    /// Remove all handlers for a specific event.
    @discardableResult
    public func unbind(event: String) -> Self {
        lock.lock()
        eventHandlers.removeValue(forKey: event)
        lock.unlock()
        return self
    }

    /// Send a JSON-serialisable dictionary over the WebSocket.
    public func send(_ message: [String: Any]) {
        guard let task = webSocketTask, state == .connected else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: message)
            let string = String(decoding: data, as: UTF8.self)
            task.send(.string(string)) { [weak self] error in
                if let error {
                    print("[AmarWave] Send error: \(error.localizedDescription)")
                    self?.fireHandlers(event: "error", data: error)
                }
            }
        } catch {
            print("[AmarWave] JSON serialisation error: \(error)")
        }
    }

    // MARK: - Internal

    func connect() {
        guard state == .initialized || state == .disconnected || state == .failed else { return }
        isDisconnectedIntentionally = false
        openSocket()
    }

    func disconnect() {
        isDisconnectedIntentionally = true
        stopReconnectTimer()
        stopPing()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        retryCount = 0
        state = .disconnected
    }

    // MARK: - Socket lifecycle

    private func openSocket() {
        state = .connecting

        let scheme = config.useTLS ? "wss" : "ws"
        let port   = config.useTLS ? config.wssPort : config.wsPort
        guard let url = URL(string: "\(scheme)://\(config.wsHost):\(port)\(config.wsPath)?app_key=\(appKey)") else {
            print("[AmarWave] Invalid WebSocket URL.")
            state = .failed
            return
        }

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveNext()
    }

    private func receiveNext() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if !self.isDisconnectedIntentionally {
                    print("[AmarWave] Receive error: \(error.localizedDescription)")
                    self.handleDisconnect()
                }
            case .success(let message):
                switch message {
                case .string(let text):    self.parseMessage(text)
                case .data(let data):      self.parseMessage(String(decoding: data, as: UTF8.self))
                @unknown default:          break
                }
                self.receiveNext() // recursive — keep reading
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // Wait for the server's connection_established message
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard !isDisconnectedIntentionally else { return }
        handleDisconnect()
    }

    // MARK: - Message parsing

    private func parseMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else { return }

        let rawData = json["data"]
        let channel = json["channel"] as? String

        // Parse nested JSON string (server sends data as a JSON-encoded string)
        let parsedData: Any
        if let dataString = rawData as? String,
           let innerData = dataString.data(using: .utf8),
           let innerJson = try? JSONSerialization.jsonObject(with: innerData) {
            parsedData = innerJson
        } else {
            parsedData = rawData ?? [:]
        }

        switch event {
        case "amarwave:connection_established":
            if let dict = parsedData as? [String: Any],
               let socketId = dict["socket_id"] as? String {
                self.socketId = socketId
                let wasRetrying = retryCount > 0
                retryCount = 0
                state = .connected
                startPing()
                if wasRetrying { onReconnected?() }
            }

        case "amarwave:ping":
            send(["event": "amarwave:pong", "data": [:]])

        case "amarwave:pong":
            stopPongTimer()

        case "amarwave:error":
            fireHandlers(event: "error", data: parsedData)

        default:
            onMessage?(event, channel, parsedData)
        }
    }

    // MARK: - Ping / Pong

    private func startPing() {
        stopPing()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pingTimer = Timer.scheduledTimer(
                withTimeInterval: self.config.activityTimeout,
                repeats: true
            ) { [weak self] _ in self?.sendPing() }
        }
    }

    private func stopPing() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
            self?.stopPongTimer()
        }
    }

    private func sendPing() {
        let statsData: [String: Any] = config.disableStats ? ["stats": false] : [:]
        send(["event": "amarwave:ping", "data": statsData])
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pongTimer = Timer.scheduledTimer(
                withTimeInterval: self.config.pongTimeout,
                repeats: false
            ) { [weak self] _ in
                print("[AmarWave] Pong timeout — reconnecting.")
                self?.handleDisconnect()
            }
        }
    }

    private func stopPongTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.pongTimer?.invalidate()
            self?.pongTimer = nil
        }
    }

    // MARK: - Reconnect

    private func handleDisconnect() {
        stopPing()
        webSocketTask?.cancel()
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        socketId = nil
        state = .disconnected

        let maxRetries = config.maxRetries
        if maxRetries > 0 && retryCount >= maxRetries {
            state = .failed
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let delay = min(
            config.reconnectDelay * pow(2.0, Double(retryCount)),
            config.maxReconnectDelay
        )
        retryCount += 1
        print("[AmarWave] Reconnecting in \(String(format: "%.1f", delay))s (attempt \(retryCount))…")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.openSocket()
            }
        }
    }

    private func stopReconnectTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.reconnectTimer?.invalidate()
            self?.reconnectTimer = nil
        }
    }

    // MARK: - Event firing

    private func fireHandlers(event: String, data: Any) {
        lock.lock()
        let handlers = eventHandlers[event] ?? []
        lock.unlock()
        handlers.forEach { $0(data) }
    }
}
