import Darwin
import Foundation

/// Discord Rich Presence bridge for macOS Discord clients (Official Discord, Vesktop, Discord Canary, etc.).
/// Connects to macOS unix domain sockets (`discord-ipc-0` through `discord-ipc-9`) and sends
/// active game status when SteamOS reports a game has focus.
///
/// Design note: Discord clients and Vesktop's arRPC track presence per persistent socket connection.
/// Closing the socket immediately removes the presence in Discord. Therefore, we maintain a persistent
/// socket connection while a game is active and focused, and only close it when focus is lost or
/// presence is cleared.
final class DiscordRPCBridge {
    static let shared = DiscordRPCBridge()

    /// Official "Steam" Discord application ID. Recognized by Discord and Vesktop.
    private static let steamClientId = "1441992353979170936"

    private let queue = DispatchQueue(label: "es.fxgam.steamac.discord-rpc", qos: .utility)
    private var socketFd: Int32 = -1
    private var activeClientId: String?
    private var currentAppId: Int?
    private var currentGameName: String?
    private var gameStartTime: Int?
    private var retryTimer: DispatchSourceTimer?

    var isEnabled: Bool {
        LauncherSettings.shared.discordRPC
    }

    init() {}

    deinit {
        disconnect()
    }

    // MARK: - Public API

    func start() {
        // Presence is connected on demand when a game gains focus.
    }

    func settingsChanged() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.isEnabled {
                if let id = self.currentAppId, id > 0 {
                    self.updatePresence(appId: id, name: self.currentGameName)
                }
            } else {
                self.clearPresence()
                self.disconnect()
                self.cancelRetry()
            }
        }
    }

    func gameFocused(appId: Int, name: String? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            guard appId > 0 else {
                if self.isEnabled {
                    self.clearPresence()
                    self.disconnect()
                }
                return
            }
            if self.currentAppId != appId {
                self.gameStartTime = Int(Date().timeIntervalSince1970)
                // If switching games, disconnect to re-handshake with appropriate client ID if needed
                self.disconnect()
            }
            self.currentAppId = appId
            if let name = name, !name.isEmpty {
                self.currentGameName = name
            }
            if self.isEnabled {
                self.updatePresence(appId: appId, name: self.currentGameName)
            }
        }
    }

    func gameNameResolved(appId: Int, name: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.currentAppId == appId {
                self.currentGameName = name
                if self.isEnabled {
                    self.updatePresence(appId: appId, name: name)
                }
            }
        }
    }

    func nonGameFocused() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.currentAppId = nil
            self.currentGameName = nil
            self.gameStartTime = nil
            self.cancelRetry()
            if self.isEnabled {
                self.clearPresence()
                self.disconnect()
            }
        }
    }

    // MARK: - Socket connection & IPC

    private static func findIPCSocket() -> String? {
        var searchDirs = [String]()
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
            searchDirs.append(tmp)
        }
        searchDirs.append("/tmp")

        let fm = FileManager.default
        let userTemp = NSTemporaryDirectory()
        if !searchDirs.contains(userTemp) {
            searchDirs.append(userTemp)
        }

        // Search for discord-ipc-0 through discord-ipc-9
        for dir in searchDirs {
            for pipe in 0...9 {
                let candidate = (dir as NSString).appendingPathComponent("discord-ipc-\(pipe)")
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                    return candidate
                }
            }
        }
        return nil
    }

    private func connectIfNeeded(clientId: String) -> Bool {
        if socketFd >= 0 {
            if activeClientId == clientId {
                return true
            }
            disconnect()
        }

        guard let socketPath = Self.findIPCSocket() else {
            scheduleRetry()
            return false
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            scheduleRetry()
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { src in raw.copyBytes(from: src.prefix(raw.count)) }
        }

        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectRes == 0 else {
            Darwin.close(fd)
            scheduleRetry()
            return false
        }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        self.socketFd = fd
        self.activeClientId = clientId

        // Handshake: Opcode 0
        let handshakeObj: [String: Any] = ["v": 1, "client_id": clientId]
        guard sendPacket(opcode: 0, json: handshakeObj),
              readPacket() != nil else {
            disconnect()
            scheduleRetry()
            return false
        }

        log("Discord RPC: Connected to macOS Discord client at \(socketPath) (client_id: \(clientId))")
        cancelRetry()
        return true
    }

    private func disconnect() {
        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
        }
        activeClientId = nil
    }

    // MARK: - Frame formatting

    private func sendPacket(opcode: UInt32, json: [String: Any]) -> Bool {
        guard socketFd >= 0 else { return false }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: []) else { return false }

        var header = Data(capacity: 8)
        var leOp = opcode.littleEndian
        var leLen = UInt32(data.count).littleEndian
        header.append(Data(bytes: &leOp, count: 4))
        header.append(Data(bytes: &leLen, count: 4))

        let packet = header + data
        return packet.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var written = 0
            while written < packet.count {
                let n = Darwin.write(socketFd, base + written, packet.count - written)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += n
            }
            return true
        }
    }

    private func readPacket() -> [String: Any]? {
        guard socketFd >= 0 else { return nil }
        var header = [UInt8](repeating: 0, count: 8)
        let headerReadOk = header.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            var readHeader = 0
            while readHeader < 8 {
                let n = Darwin.read(socketFd, base + readHeader, 8 - readHeader)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                readHeader += n
            }
            return true
        }
        guard headerReadOk else { return nil }

        let length = UInt32(header[4]) | (UInt32(header[5]) << 8) | (UInt32(header[6]) << 16) | (UInt32(header[7]) << 24)
        guard length < (1024 * 1024) else { return nil }

        var body = [UInt8](repeating: 0, count: Int(length))
        let bodyReadOk = body.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            var readBody = 0
            while readBody < Int(length) {
                let n = Darwin.read(socketFd, base + readBody, Int(length) - readBody)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                readBody += n
            }
            return true
        }
        guard bodyReadOk else { return nil }

        let bodyData = Data(body)
        return (try? JSONSerialization.jsonObject(with: bodyData, options: [])) as? [String: Any]
    }

    // MARK: - Activity payload

    private func updatePresence(appId: Int, name: String?) {
        let clientId = Self.steamClientId
        guard connectIfNeeded(clientId: clientId) else { return }

        let gameTitle = name ?? "Steam Game (AppID \(appId))"
        let startTimestamp = gameStartTime ?? Int(Date().timeIntervalSince1970)
        let iconUrl = "https://shared.steamstatic.com/store_item_assets/steam/apps/\(appId)/header.jpg"

        let assets: [String: Any] = [
            "large_image": iconUrl,
            "large_text": gameTitle
        ]

        let activity: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "activity": [
                    "name": gameTitle,
                    "details": gameTitle,
                    "state": "SteamOS on Mac",
                    "timestamps": ["start": startTimestamp],
                    "assets": assets
                ]
            ],
            "nonce": UUID().uuidString
        ]

        log("Discord RPC: updating presence for \(gameTitle) (AppID \(appId))")
        if sendPacket(opcode: 1, json: activity) {
            _ = readPacket()
        } else {
            disconnect()
            scheduleRetry()
        }
    }

    private func clearPresence() {
        guard socketFd >= 0 else { return }

        let clearPayload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "activity": NSNull()
            ],
            "nonce": UUID().uuidString
        ]

        if sendPacket(opcode: 1, json: clearPayload) {
            _ = readPacket()
        } else {
            disconnect()
        }
    }

    // MARK: - Retry

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isEnabled else { return }
            guard let id = self.currentAppId, id > 0 else { return }
            self.updatePresence(appId: id, name: self.currentGameName)
        }
        timer.resume()
        retryTimer = timer
    }

    private func cancelRetry() {
        retryTimer?.cancel()
        retryTimer = nil
    }
}
