import Foundation

final class SocketServer {
    static let socketPath = "/tmp/notchikko.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let serverQueue = DispatchQueue(label: "com.notchikko.socket.server", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.notchikko.socket.client", qos: .userInitiated, attributes: .concurrent)

    /// 待响应的连接 (request_id → client fd)
    private var pendingResponses: [String: Int32] = [:]
    private let pendingLock = NSLock()

    var onEvent: ((HookEvent) -> Void)?
    /// 需要审批的事件回调（包含 request_id）
    var onApprovalRequest: ((HookEvent) -> Void)?

    func start() {
        serverQueue.async { [weak self] in
            self?.startServer()
        }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        // 关闭所有待响应连接
        pendingLock.lock()
        for (_, fd) in pendingResponses {
            close(fd)
        }
        pendingResponses.removeAll()
        pendingLock.unlock()
        unlink(Self.socketPath)
    }

    /// 向指定 request_id 的客户端回写审批结果
    func respond(requestId: String, json: Data) {
        pendingLock.lock()
        guard let fd = pendingResponses.removeValue(forKey: requestId) else {
            pendingLock.unlock()
            return
        }
        pendingLock.unlock()

        clientQueue.async {
            json.withUnsafeBytes { ptr in
                _ = write(fd, ptr.baseAddress!, json.count)
            }
            // 写完后加换行符确保 Python 能读完
            "\n".withCString { ptr in
                _ = write(fd, ptr, 1)
            }
            close(fd)
        }
    }

    private func startServer() {
        if isSocketActive(Self.socketPath) {
            print("[SocketServer] Another instance is already listening")
            return
        }
        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("[SocketServer] Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strcpy(buf, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            print("[SocketServer] Failed to bind: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        chmod(Self.socketPath, 0o600)

        guard listen(serverSocket, 10) == 0 else {
            print("[SocketServer] Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        print("[SocketServer] Listening on \(Self.socketPath)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: serverQueue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        acceptSource?.resume()
    }

    private func acceptConnections() {
        while true {
            let clientSocket = accept(serverSocket, nil, nil)
            guard clientSocket >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }

            clientQueue.async { [weak self] in
                self?.handleClient(clientSocket)
            }
        }
    }

    private func handleClient(_ clientSocket: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        var pfd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)
        while true {
            let pollResult = poll(&pfd, 1, 500)
            guard pollResult > 0 else { break }

            let bytesRead = read(clientSocket, &buffer, buffer.count)
            if bytesRead > 0 {
                data.append(contentsOf: buffer[0..<bytesRead])
            } else {
                break
            }
        }

        guard !data.isEmpty else {
            print("[SocketServer] Empty data from client")
            close(clientSocket)
            return
        }

        print("[SocketServer] Received \(data.count) bytes: \(String(data: data, encoding: .utf8) ?? "?")")

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            print("[SocketServer] Failed to parse event, raw: \(String(data: data, encoding: .utf8) ?? "?")")
            close(clientSocket)
            return
        }

        print("[SocketServer] Parsed event: \(event.event) session=\(event.sessionId) tool=\(event.tool ?? "") hasRequestId=\(event.requestId != nil)")

        // 如果有 request_id，说明是审批请求 — 保持连接等待回写
        if let requestId = event.requestId, !requestId.isEmpty {
            pendingLock.lock()
            pendingResponses[requestId] = clientSocket
            pendingLock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.onApprovalRequest?(event)
            }
        } else {
            // fire-and-forget — 正常关闭连接
            close(clientSocket)

            DispatchQueue.main.async { [weak self] in
                self?.onEvent?(event)
            }
        }
    }

    private func isSocketActive(_ path: String) -> Bool {
        let testSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard testSocket >= 0 else { return false }
        defer { close(testSocket) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strcpy(buf, ptr)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(testSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        return result == 0
    }
}
