import Foundation

final class SocketServer {
    static let socketPath = "/tmp/notchikko.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let serverQueue = DispatchQueue(label: "com.notchikko.socket.server", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "com.notchikko.socket.client", qos: .userInitiated, attributes: .concurrent)

    var onEvent: ((HookEvent) -> Void)?

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
        unlink(Self.socketPath)
    }

    private func startServer() {
        // 清理旧 socket（检测是否有其他进程在用）
        if isSocketActive(Self.socketPath) {
            print("[SocketServer] Another instance is already listening")
            return
        }
        unlink(Self.socketPath)

        // 创建 socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("[SocketServer] Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        // Bind
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
        defer { close(clientSocket) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        // 带超时的读取
        var pfd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)
        while true {
            let pollResult = poll(&pfd, 1, 500) // 500ms 超时
            guard pollResult > 0 else { break }

            let bytesRead = read(clientSocket, &buffer, buffer.count)
            if bytesRead > 0 {
                data.append(contentsOf: buffer[0..<bytesRead])
            } else {
                break
            }
        }

        guard !data.isEmpty else { return }

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            print("[SocketServer] Failed to parse event")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
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
