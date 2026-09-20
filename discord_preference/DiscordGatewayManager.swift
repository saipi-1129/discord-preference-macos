import Foundation
import Combine

class DiscordGatewayManager: ObservableObject {
    @Published var connectionStatus: String = "Disconnected"
    @Published var lastError: String? = nil

    private var _webSocket: URLSessionWebSocketTask?
    private var _heartbeatTimer: Timer?
    private var _token: String = ""
    private var _applicationId: String = ""
    private var _lastSequenceNumber: Int?
    private var _heartbeatInterval: TimeInterval = 41.25
    private var _shouldReconnect: Bool = false
    private var _reconnectAttempts: Int = 0
    private let _maxReconnectAttempts: Int = 5
    private var _lastPresenceUpdate: Date = .distantPast
    private let _presenceUpdateInterval: TimeInterval = 30.0
    private var _sendQueue: [(String, URLSessionWebSocketTask)] = []
    private var _isSending: Bool = false
    private var _lastSentSongTitle: String = ""
    private var _latestPresenceKey: String = ""
    private var _externalAssetCache: [String: String] = [:] // artworkURL -> mp:external/...

    // MARK: - Public API

    func connect(with token: String, applicationId: String = "") {
        _token = token
        _applicationId = applicationId
        _shouldReconnect = true
        _reconnectAttempts = 0
        lastError = nil
        BackgroundAudioManager.shared.start()
        openWebSocket()
    }

    func disconnect() {
        _shouldReconnect = false
        _heartbeatTimer?.invalidate()
        _heartbeatTimer = nil
        _webSocket?.cancel(with: .normalClosure, reason: nil)
        _webSocket = nil
        connectionStatus = "Disconnected"
        BackgroundAudioManager.shared.stop()
    }

    func updatePresence(songTitle: String, artist: String, albumTitle: String, artworkURL: String?, appleMusicURL: String?, playbackDuration: TimeInterval, currentPlaybackTime: TimeInterval, isPlaying: Bool, force: Bool = false) {
        guard _webSocket != nil, connectionStatus == "Connected" else { return }

        // Throttle: skip if same song and within interval (unless forced)
        if !force {
            let now = Date()
            guard now.timeIntervalSince(_lastPresenceUpdate) >= _presenceUpdateInterval else { return }
        }

        // Skip duplicate updates for same song
        let songKey = "\(songTitle)-\(artist)-\(albumTitle)-\(isPlaying)"
        if !force && songKey == _lastSentSongTitle {
            return
        }
        _lastSentSongTitle = songKey
        _latestPresenceKey = songKey
        _lastPresenceUpdate = Date()

        print("[Presence] song=\(songTitle) artworkURL=\(artworkURL ?? "nil") appId=\(_applicationId)")

        var activities: [[String: Any]] = []
        if isPlaying {
            let activity = buildAppleMusicActivity(
                songTitle: songTitle,
                artist: artist,
                albumTitle: albumTitle,
                appleMusicURL: appleMusicURL,
                playbackDuration: playbackDuration,
                currentPlaybackTime: currentPlaybackTime
            )

            if !_applicationId.isEmpty {
                guard let artworkURL else {
                    sendPresencePayload(activities: [activity])
                    return
                }

                resolveExternalAsset(url: artworkURL) { [weak self] externalURL in
                    guard let self else { return }
                    guard self._latestPresenceKey == songKey else { return }
                    guard let externalURL else {
                        self.sendPresencePayload(activities: [activity])
                        return
                    }

                    var richActivity = self.buildAppleMusicActivity(
                        songTitle: songTitle,
                        artist: artist,
                        albumTitle: albumTitle,
                        appleMusicURL: appleMusicURL,
                        playbackDuration: playbackDuration,
                        currentPlaybackTime: currentPlaybackTime
                    )
                    richActivity["application_id"] = self._applicationId
                    let searchURL = appleMusicURL ?? self.appleMusicSearchURL(songTitle: songTitle, artist: artist)
                    richActivity["buttons"] = ["Apple Musicで再生"]
                    richActivity["metadata"] = [
                        "button_urls": [searchURL]
                    ]
                    richActivity["assets"] = [
                        "large_image": externalURL,
                        "large_text": albumTitle.isEmpty ? songTitle : albumTitle
                    ]
                    self.sendPresencePayload(activities: [richActivity])
                }
                return
            } else {
                // No application ID — text-only presence
                activities.append(activity)
            }
        }

        sendPresencePayload(activities: activities)
    }

    private func buildAppleMusicActivity(songTitle: String, artist: String, albumTitle: String, appleMusicURL: String?, playbackDuration: TimeInterval, currentPlaybackTime: TimeInterval) -> [String: Any] {
        var activity: [String: Any] = [
            "name": songTitle,
            "type": 2,
            "details": songTitle,
            "state": artist.isEmpty ? "Apple Musicで再生中" : "\(artist) ・ Apple Musicで再生中"
        ]

        if playbackDuration > 0 {
            let now = Date().timeIntervalSince1970 * 1000
            let start = Int(now - max(0, currentPlaybackTime) * 1000)
            let end = start + Int(playbackDuration * 1000)
            activity["timestamps"] = [
                "start": start,
                "end": end
            ]
        }

        if !albumTitle.isEmpty {
            activity["assets"] = [
                "large_text": albumTitle
            ]
        }

        return activity
    }

    private func appleMusicSearchURL(songTitle: String, artist: String) -> String {
        let query = "\(songTitle) \(artist)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? songTitle
        return "https://music.apple.com/search?term=\(query)"
    }

    // MARK: - External Asset Resolution

    private func resolveExternalAsset(url: String, completion: @escaping (String?) -> Void) {
        // Check cache
        if let cached = _externalAssetCache[url] {
            completion(cached)
            return
        }

        guard !_applicationId.isEmpty else {
            completion(nil)
            return
        }

        // Call Discord API to convert external URL to mp:external/ format
        let apiURL = URL(string: "https://discord.com/api/v10/applications/\(_applicationId)/external-assets")!
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(_token, forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["urls": [url]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error {
                    print("[Discord] External asset error: \(error)")
                    completion(nil)
                    return
                }
                if let http = response as? HTTPURLResponse {
                    print("[Discord] External asset HTTP \(http.statusCode)")
                }
                if let data {
                    let raw = String(data: data, encoding: .utf8) ?? "nil"
                    print("[Discord] External asset response: \(raw)")
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let first = json.first,
                      let externalAssetPath = first["external_asset_path"] as? String else {
                    print("[Discord] External asset parse failed")
                    completion(nil)
                    return
                }
                let result = externalAssetPath.hasPrefix("mp:") ? externalAssetPath : "mp:\(externalAssetPath)"
                print("[Discord] External asset resolved: \(result)")
                self?._externalAssetCache[url] = result
                completion(result)
            }
        }.resume()
    }

    private func sendPresencePayload(activities: [[String: Any]]) {
        sendPayload([
            "op": 3,
            "d": [
                "since": NSNull(),
                "activities": activities,
                "status": "online",
                "afk": false
            ]
        ])
    }

    // MARK: - Connection

    private func openWebSocket() {
        _heartbeatTimer?.invalidate()
        _heartbeatTimer = nil
        _webSocket?.cancel(with: .normalClosure, reason: nil)
        _webSocket = nil

        connectionStatus = "Connecting..."

        let url = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
        let ws = URLSession.shared.webSocketTask(with: url)
        ws.maximumMessageSize = 10 * 1024 * 1024
        _webSocket = ws
        ws.resume()

        startReceiving(ws: ws)
    }

    nonisolated private func startReceiving(ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                let text: String? = {
                    switch message {
                    case .string(let t): return t
                    case .data(let d): return String(data: d, encoding: .utf8)
                    @unknown default: return nil
                    }
                }()

                if let text {
                    DispatchQueue.main.async {
                        self.handlePayload(text: text, ws: ws)
                    }
                }

                self.startReceiving(ws: ws)

            case .failure(let error):
                print("[WS] Receive error: \(error)")
                DispatchQueue.main.async {
                    guard self._webSocket === ws else { return }
                    self._webSocket = nil
                    self._heartbeatTimer?.invalidate()
                    self._heartbeatTimer = nil

                    if self._shouldReconnect {
                        self.lastError = "接続が切れました。再接続中..."
                        self.attemptReconnect()
                    } else {
                        self.lastError = "接続エラー: \(error.localizedDescription)"
                        self.connectionStatus = "Disconnected"
                    }
                }
            }
        }
    }

    // MARK: - Payload Handler

    private func handlePayload(text: String, ws: URLSessionWebSocketTask) {
        guard _webSocket === ws else { return }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int else { return }

        let t = json["t"] as? String ?? ""
        print("[WS] op=\(op) t=\(t)")

        if let s = json["s"] as? Int {
            _lastSequenceNumber = s
        }

        switch op {
        case 10: // Hello
            if let d = json["d"] as? [String: Any],
               let interval = d["heartbeat_interval"] as? Double {
                _heartbeatInterval = interval / 1000.0
                print("[WS] Hello! heartbeat=\(_heartbeatInterval)s")
                sendIdentify()
                let jitter = Double.random(in: 0...1)
                let firstHeartbeatDelay = _heartbeatInterval * jitter
                _heartbeatTimer?.invalidate()
                _heartbeatTimer = Timer.scheduledTimer(withTimeInterval: firstHeartbeatDelay, repeats: false) { [weak self] _ in
                    self?.sendHeartbeat()
                    self?._heartbeatTimer = Timer.scheduledTimer(withTimeInterval: self?._heartbeatInterval ?? 41.25, repeats: true) { [weak self] _ in
                        self?.sendHeartbeat()
                    }
                }
            }

        case 11: // Heartbeat ACK
            break

        case 0: // Dispatch
            if t == "READY" {
                print("[WS] Authenticated!")
                _lastPresenceUpdate = .distantPast
                _lastSentSongTitle = ""
                connectionStatus = "Connected"
                lastError = nil
                _reconnectAttempts = 0
            }

        case 7:
            print("[WS] Reconnect requested")
            openWebSocket()

        case 9:
            print("[WS] Invalid session")
            _shouldReconnect = false
            connectionStatus = "Disconnected"
            lastError = "セッションが無効です。トークンを確認してください。"
            _webSocket?.cancel(with: .normalClosure, reason: nil)
            _webSocket = nil

        default:
            break
        }
    }

    // MARK: - Send

    private func sendIdentify() {
        #if os(macOS)
        let properties: [String: Any] = [
            "os": "macOS",
            "browser": "Discord macOS",
            "device": "Mac",
            "system_locale": Locale.current.identifier,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        #else
        let properties: [String: Any] = [
            "os": "iOS",
            "browser": "Discord iOS",
            "device": "iPhone",
            "system_locale": "ja-JP",
            "os_version": "17.0"
        ]
        #endif

        sendPayload([
            "op": 2,
            "d": [
                "token": _token,
                "capabilities": 30717,
                "properties": properties,
                "presence": [
                    "status": "online",
                    "since": 0,
                    "activities": [],
                    "afk": false
                ],
                "compress": false
            ]
        ])
    }

    private func sendHeartbeat() {
        sendPayload([
            "op": 1,
            "d": _lastSequenceNumber ?? NSNull()
        ])
    }

    private func sendPayload(_ payload: [String: Any]) {
        guard let ws = _webSocket,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }

        _sendQueue.append((str, ws))
        processNextSend()
    }

    private func processNextSend() {
        guard !_isSending, !_sendQueue.isEmpty else { return }
        let (str, ws) = _sendQueue.removeFirst()
        guard ws === _webSocket else {
            processNextSend()
            return
        }

        _isSending = true
        ws.send(.string(str)) { [weak self] error in
            DispatchQueue.main.async {
                self?._isSending = false
                if let error {
                    print("[WS] Send error: \(error)")
                } else {
                    print("[WS] Send OK")
                }
                self?.processNextSend()
            }
        }
    }

    // MARK: - Reconnect

    private func attemptReconnect() {
        guard _shouldReconnect, _reconnectAttempts < _maxReconnectAttempts else {
            if _reconnectAttempts >= _maxReconnectAttempts {
                connectionStatus = "Disconnected"
                lastError = "再接続に失敗しました"
            }
            return
        }

        _reconnectAttempts += 1
        let delay = min(pow(2.0, Double(_reconnectAttempts)), 30.0)
        connectionStatus = "Reconnecting (\(_reconnectAttempts)/\(_maxReconnectAttempts))..."

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self._shouldReconnect else { return }
            self.openWebSocket()
        }
    }
}
