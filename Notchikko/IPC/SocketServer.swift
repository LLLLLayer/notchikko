import Foundation

final class SocketServer {
    static let socketPath = "/tmp/notchikko.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let serverQueue = DispatchQueue(label: "com.notchikko.socket.server", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.notchikko.socket.client", qos: .userInitiated, attributes: .concurrent)

    /// 待响应的连接 (request_id → client fd)
    private var pendingResponses: [String: Int32] = [:]
    /// 监控远端断开的 dispatch source (request_id → source)
    private var pendingMonitors: [String: DispatchSourceRead] = [:]
    private let pendingLock = NSLock()

    var onEvent: ((HookEvent) -> Void)?
    /// 需要审批的事件回调（包含 request_id）
    var onApprovalRequest: ((HookEvent) -> Void)?
    /// Hook 进程断开回调（用户按 Esc 等场景，自动清理审批卡片）
    var onApprovalDisconnect: ((String) -> Void)?

    func start() {
        serverQueue.async { [weak self] in
            self?.startServer()
        }
    }

    func stop() {
        // 先清除 handler 防止 cancel 期间还在 accept
        acceptSource?.setEventHandler(handler: nil)
        acceptSource?.cancel()
        acceptSource = nil
        serverQueue.sync {
            if self.serverSocket >= 0 {
                close(self.serverSocket)
                self.serverSocket = -1
            }
        }
        // 关闭所有待响应连接和监控源
        pendingLock.lock()
        for (_, source) in pendingMonitors { source.cancel() }
        pendingMonitors.removeAll()
        for (_, fd) in pendingResponses { close(fd) }
        pendingResponses.removeAll()
        pendingLock.unlock()
        unlink(Self.socketPath)
    }

    /// 关闭待响应连接但不发送数据（超时清理用）
    func closePending(requestId: String) {
        pendingLock.lock()
        guard let fd = pendingResponses.removeValue(forKey: requestId) else {
            pendingLock.unlock()
            return
        }
        pendingMonitors.removeValue(forKey: requestId)?.cancel()
        pendingLock.unlock()
        clientQueue.async { close(fd) }
    }

    /// 向指定 request_id 的客户端回写审批结果
    func respond(requestId: String, json: Data) {
        pendingLock.lock()
        guard let fd = pendingResponses.removeValue(forKey: requestId) else {
            pendingLock.unlock()
            return
        }
        pendingMonitors.removeValue(forKey: requestId)?.cancel()
        pendingLock.unlock()

        // fd 已从 pendingResponses 移除，stop() 不会再 close 它
        // 这里是唯一持有者，安全写入后关闭
        let dataCopy = json
        clientQueue.async {
            var ok = true
            dataCopy.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { ok = false; return }
                let written = write(fd, base, dataCopy.count)
                if written != dataCopy.count {
                    Log("Socket write failed: \(written)/\(dataCopy.count), errno=\(errno)", tag: "Socket")
                    ok = false
                }
            }
            if ok {
                _ = write(fd, "\n", 1)
            }
            close(fd)
        }
    }

    private func startServer() {
        if isSocketActive(Self.socketPath) {
            Log("Another instance is already listening", tag: "Socket")
            return
        }
        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            Log("Failed to create socket: \(errno)", tag: "Socket")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                _ = strlcpy(buf, ptr, pathSize)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if bindResult != 0 {
            // bind 失败可能是旧 socket 文件残留，尝试 unlink 后重试
            unlink(Self.socketPath)
            let retryResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard retryResult == 0 else {
                Log("Bind failed after retry: \(errno)", tag: "Socket")
                close(serverSocket)
                serverSocket = -1
                return
            }
        }

        chmod(Self.socketPath, 0o600)

        guard listen(serverSocket, 10) == 0 else {
            close(serverSocket)
            serverSocket = -1
            return
        }

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
            close(clientSocket)
            return
        }

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            close(clientSocket)
            return
        }

        // 如果有 request_id，说明是审批请求 — 保持连接等待回写
        if let requestId = event.requestId, !requestId.isEmpty {
            pendingLock.lock()
            pendingResponses[requestId] = clientSocket
            pendingLock.unlock()

            // 监控远端断开（用户按 Esc 等场景 → hook 进程被杀 → fd EOF）
            monitorDisconnect(fd: clientSocket, requestId: requestId)

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

    /// 用 DispatchSourceRead 监控 fd，远端关闭时自动清理
    private func monitorDisconnect(fd: Int32, requestId: String) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: clientQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }

            // 先检查 fd 是否仍归我们管（respond() 可能已 close 了它）
            self.pendingLock.lock()
            guard self.pendingResponses[requestId] != nil else {
                self.pendingLock.unlock()
                return
            }
            self.pendingLock.unlock()

            // fd 仍存活，安全 peek 检测 EOF
            var buf: UInt8 = 0
            let n = recv(fd, &buf, 1, MSG_PEEK | MSG_DONTWAIT)
            guard n == 0 else { return }

            Log("Hook disconnected: \(requestId.prefix(8))", tag: "Socket")
            source.cancel()

            self.pendingLock.lock()
            guard self.pendingResponses.removeValue(forKey: requestId) != nil else {
                self.pendingLock.unlock()
                return
            }
            self.pendingMonitors.removeValue(forKey: requestId)
            self.pendingLock.unlock()

            close(fd)
            DispatchQueue.main.async { self.onApprovalDisconnect?(requestId) }
        }
        source.resume()

        pendingLock.lock()
        pendingMonitors[requestId] = source
        pendingLock.unlock()
    }

    private func isSocketActive(_ path: String) -> Bool {
        let testSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard testSocket >= 0 else { return false }
        defer { close(testSocket) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                _ = strlcpy(buf, ptr, pathSize)
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
