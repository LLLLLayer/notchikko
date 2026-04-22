import Foundation

/// 进程发现。定时扫描运行中的 Agent 进程，为不经过 hook 的 Agent 创建 placeholder session。
/// 发现的 session 只知道进程存在，不知道当前状态（除非有 JSONL 配合）。
/// 不支持审批、不支持终端跳转。
@MainActor
final class ProcessDiscovery {
    /// 发现新 Agent 进程时回调 (sessionId, source, pid)
    var onProcessFound: ((String, String, Int) -> Void)?
    /// Agent 进程退出时回调 (sessionId)
    var onProcessExited: ((String) -> Void)?

    private var isRunning = false
    private var scanTask: Task<Void, Never>?
    /// 已发现的 Agent 进程 PID → sessionId
    private var discoveredPids: [Int: String] = [:]

    /// Hook 管理的 session IDs（跳过匹配的进程）
    var hookSessionIds: Set<String> = []

    private static let scanInterval: TimeInterval = 60

    /// 已知 Agent 进程名（精确匹配 lastPathComponent）
    private nonisolated static let agentNames: [String: String] = [
        "claude": "claude-code",
        "codex": "codex",
        "gemini": "gemini-cli",
        "traecli": "trae-cli",
        "coco": "trae-cli",
    ]

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Log("ProcessDiscovery started", tag: "Discovery")

        scanTask = Task {
            while !Task.isCancelled {
                await scan()
                try? await Task.sleep(for: .seconds(Self.scanInterval))
            }
        }
    }

    func stop() {
        isRunning = false
        scanTask?.cancel()
        scanTask = nil
        Log("ProcessDiscovery stopped", tag: "Discovery")
    }

    // MARK: - 扫描

    private func scan() async {
        // 在后台线程执行 ps（避免阻塞主线程）
        let processes = await Task.detached { Self.listProcesses() }.value
        var seenPids: Set<Int> = []

        for proc in processes {
            guard let source = Self.matchAgent(proc) else { continue }
            seenPids.insert(proc.pid)

            // 已知进程 → 跳过
            if discoveredPids[proc.pid] != nil { continue }

            let sessionId = "discovered-\(source)-\(proc.pid)"

            discoveredPids[proc.pid] = sessionId
            Log("Discovered agent process: \(source) pid=\(proc.pid)", tag: "Discovery")
            onProcessFound?(sessionId, source, proc.pid)
        }

        // 清理已退出的进程 → 发送 sessionEnd
        let stalePids = discoveredPids.keys.filter { !seenPids.contains($0) }
        for pid in stalePids {
            if let sessionId = discoveredPids.removeValue(forKey: pid) {
                Log("Agent process exited: pid=\(pid), session=\(sessionId.prefix(16))", tag: "Discovery")
                onProcessExited?(sessionId)
            }
        }
    }

    /// 精确匹配进程名是否为已知 Agent
    private nonisolated static func matchAgent(_ proc: ProcessInfo) -> String? {
        let comm = (proc.comm as NSString).lastPathComponent.lowercased()
        return agentNames[comm]
    }

    /// 当前 ps 中活跃的 Agent source 集合（供 TranscriptPoller 做 pid 校验）。
    /// nonisolated：可在后台线程调用，避免阻塞主线程。
    nonisolated static func liveAgentSources() -> Set<String> {
        var sources: Set<String> = []
        for proc in listProcesses() {
            if let source = matchAgent(proc) { sources.insert(source) }
        }
        return sources
    }

    // MARK: - 进程列表

    private struct ProcessInfo: Sendable {
        let pid: Int
        let comm: String
        let args: String
    }

    /// 执行 ps 获取进程列表（nonisolated，可在后台线程调用）
    private nonisolated static func listProcesses() -> [ProcessInfo] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid=,comm=,args="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // 先读再 waitUntilExit（避免 pipe 死锁）
        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var results: [ProcessInfo] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = Int(parts[0]) else { continue }
            let comm = String(parts[1])
            let args = parts.count > 2 ? String(parts[2]) : ""
            results.append(ProcessInfo(pid: pid, comm: comm, args: args))
        }
        return results
    }
}
