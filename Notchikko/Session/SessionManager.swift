import Foundation

@MainActor @Observable
final class SessionManager {
    private(set) var currentState: NotchikkoState = .sleeping
    /// handleEvent 执行前的状态（用于判断过时的 notification 事件）
    private(set) var previousState: NotchikkoState = .sleeping
    private(set) var sessions: [String: SessionInfo] = [:]

    /// 弹幕事件：每次活跃 session 触发 tool 时递增，附带工具名
    private(set) var danmakuToolEvent: (id: Int, tool: String) = (0, "")
    /// 弹幕事件：session 切换时递增，附带项目名
    private(set) var danmakuSessionEvent: (id: Int, name: String) = (0, "")
    private var danmakuCounter = 0

    /// nil = 自动跟踪最新活跃 session
    var pinnedSessionId: String? = nil

    private var idleTimer: Task<Void, Never>?
    private var sleepTimer: Task<Void, Never>?
    private var returnTimer: Task<Void, Never>?

    struct SessionInfo {
        let id: String
        let cwd: String
        let source: String       // CLI 来源: "claude-code", "codex", "trae-cli"
        var lastEvent: Date
        var phase: SessionPhase

        // v0.3: 上下文信息
        var lastPrompt: String?              // 用户最近 prompt
        var lastToolSummary: String?         // "Bash: xcodebuild ..." / "Edit: file.swift"
        var matchedTerminal: TerminalMatch?  // 终端匹配缓存
        var terminalPid: Int?                // 终端进程 PID（hook 进程树检测）
        var terminalTty: String?             // 终端 tty 路径（iTerm2 tab 定位）
        var pidChain: [Int]?                 // hook→终端的 PID 链（VS Code 终端定位）
        var isBypassMode: Bool = false       // --dangerously-skip-permissions

        var cwdName: String {
            (cwd as NSString).lastPathComponent
        }

        /// 副标题：prompt → tool summary → cwd（降级链）
        var subtitle: String {
            if let prompt = lastPrompt, !prompt.isEmpty {
                // 去除换行，截断到 50 字符
                let cleaned = prompt.components(separatedBy: .newlines).joined(separator: " ")
                let trimmed = cleaned.prefix(50)
                return trimmed.count < cleaned.count ? "\(trimmed)..." : String(trimmed)
            }
            if let tool = lastToolSummary, !tool.isEmpty {
                return tool
            }
            return cwdName
        }

        var phaseDisplayName: String {
            switch phase {
            case .waitingForInput: return String(localized: "session.phase.idle")
            case .processing: return String(localized: "session.phase.thinking")
            case .runningTool(let t): return t.lowercased()
            case .compacting: return String(localized: "session.phase.sweeping")
            case .ended: return String(localized: "session.phase.ended")
            }
        }
    }

    struct TerminalMatch {
        let bundleId: String
        let appName: String      // "iTerm2", "Ghostty", "VSCode"
    }

    enum SessionPhase: Equatable {
        case waitingForInput
        case processing
        case runningTool(String)
        case compacting
        case ended
    }

    // MARK: - 当前活跃 session

    /// 当前展示的 session（pinned 优先，否则最新活跃）
    var activeSessionId: String? {
        if let pinned = pinnedSessionId, sessions[pinned] != nil,
           sessions[pinned]?.phase != .ended {
            return pinned
        }
        return sessions.values
            .filter { $0.phase != .ended }
            .max(by: { $0.lastEvent < $1.lastEvent })?.id
    }

    /// 活跃 session 列表（供右键菜单用，按最近活跃排序）
    var activeSessions: [SessionInfo] {
        sessions.values
            .filter { $0.phase != .ended }
            .sorted { $0.lastEvent > $1.lastEvent }
    }

    // MARK: - 绑定切换

    func pinSession(_ sessionId: String?) {
        pinnedSessionId = sessionId
        // 切换绑定后，立即根据目标 session 的 phase 更新状态
        if let sid = activeSessionId, let session = sessions[sid] {
            currentState = stateForPhase(session.phase)
            emitSessionDanmaku(session)
        } else {
            currentState = .sleeping
        }
        resetTimers()
    }

    // MARK: - 事件处理

    func handleEvent(_ event: AgentEvent) {
        previousState = currentState
        Log("handleEvent: \(event), active=\(activeSessionId?.prefix(8) ?? "nil"), state=\(currentState)", tag: "Session")
        let eventSessionId = sessionIdOf(event)

        // 收到未知 session 的事件时自动创建（应对中途安装 hook 的场景）
        ensureSession(event)

        // 每个事件都可能携带 terminalPid，更新到 session（首次检测到时生效）
        if case .sessionStart(_, _, _, let tPid, _) = event, let tPid,
           sessions[eventSessionId]?.terminalPid == nil {
            sessions[eventSessionId]?.terminalPid = tPid
        }

        switch event {
        case .sessionStart(let sid, let cwd, let source, let terminalPid, let pidChain):
            sessions[sid] = SessionInfo(
                id: sid, cwd: cwd, source: source,
                lastEvent: Date(), phase: .waitingForInput,
                terminalPid: terminalPid, pidChain: pidChain
            )
            SoundManager.shared.play(for: "session-start")
            emitSessionDanmaku(sessions[sid]!)
            if eventSessionId == activeSessionId || activeSessionId == nil {
                resetTimers()
                transition(to: .idle)
            }

        case .prompt(let sid, let text):
            sessions[sid]?.phase = .processing
            sessions[sid]?.lastEvent = Date()
            if let text, !text.isEmpty {
                sessions[sid]?.lastPrompt = text
            }
            if sid == activeSessionId {
                resetTimers()
                transition(to: .thinking)
            }

        case .toolUse(let sid, let tool, let phase):
            switch phase {
            case .pre:
                sessions[sid]?.phase = .runningTool(tool)
                sessions[sid]?.lastEvent = Date()
                sessions[sid]?.lastToolSummary = tool
                if sid == activeSessionId {
                    resetTimers()
                    transition(to: stateForTool(tool))
                    // 弹幕：所有工具都发射
                    danmakuCounter += 1
                    danmakuToolEvent = (danmakuCounter, tool)
                }
            case .post(let success):
                sessions[sid]?.lastEvent = Date()
                if sid == activeSessionId && !success {
                    resetTimers()
                    transition(to: .error)
                    scheduleReturn(to: .idle, delay: 5.0)
                }
            }

        case .stop(let sid):
            sessions[sid]?.phase = .waitingForInput
            sessions[sid]?.lastEvent = Date()
            Log("Stop: sid=\(sid.prefix(8)), active=\(activeSessionId?.prefix(8) ?? "nil"), state=\(currentState)", tag: "Session")
            if sid == activeSessionId {
                resetTimers()
                transition(to: .happy)
                // 庆祝完后，如果绑定了这个 session 且有其他活跃 session，自动切换
                scheduleAutoSwitch(from: sid, delay: 3.0)
            }

        case .error(let sid, _):
            sessions[sid]?.lastEvent = Date()
            if sid == activeSessionId {
                resetTimers()
                transition(to: .error)
                scheduleReturn(to: .idle, delay: 5.0)
            }

        case .compact(let sid):
            sessions[sid]?.phase = .compacting
            sessions[sid]?.lastEvent = Date()
            if sid == activeSessionId {
                resetTimers()
                transition(to: .sweeping)
            }

        case .sessionEnd(let sid):
            sessions[sid]?.phase = .ended
            // 如果绑定的 session 结束了，自动解绑
            if pinnedSessionId == sid {
                pinnedSessionId = nil
            }
            // 延迟移除，让菜单有时间看到 ended 状态
            let capturedSid = sid
            Task {
                try? await Task.sleep(for: .seconds(3))
                sessions.removeValue(forKey: capturedSid)
            }
            // 如果还有活跃 session，切换到最新的
            if let nextActive = activeSessionId, let session = sessions[nextActive] {
                currentState = stateForPhase(session.phase)
            } else if activeSessions.isEmpty {
                transition(to: .sleeping)
            }

        case .notification(let sid, let msg):
            let isBypass = sessions[sid]?.isBypassMode ?? false
            let approvalOn = PreferencesStore.shared.preferences.approvalCardEnabled
            // 只有需要用户操作的事件才更新 session 和切状态
            let needsUserAction = (msg == "Elicitation" || msg == "AskUserQuestion"
                || (msg == "PermissionRequest" && !isBypass && approvalOn))
            guard needsUserAction else { break }
            sessions[sid]?.lastEvent = Date()
            sessions[sid]?.phase = .waitingForInput
            if sid == activeSessionId {
                idleTimer?.cancel()
                sleepTimer?.cancel()
                currentState = .approving
                SoundManager.shared.play(for: "approving")
            }
        }
    }

    // MARK: - Tool → State 映射

    private func stateForTool(_ tool: String) -> NotchikkoState {
        switch tool {
        case "Read", "Grep", "Glob":
            return .reading
        case "Edit", "Write", "NotebookEdit":
            return .typing
        case "Bash":
            return .building
        default:
            Log("Unknown tool '\(tool)', defaulting to .typing", tag: "Session")
            return .typing
        }
    }

    private func stateForPhase(_ phase: SessionPhase) -> NotchikkoState {
        switch phase {
        case .waitingForInput: return .idle
        case .processing: return .thinking
        case .runningTool(let tool): return stateForTool(tool)
        case .compacting: return .sweeping
        case .ended: return .sleeping
        }
    }

    // MARK: - 外部控制

    /// 拖拽期间冻结所有状态变更
    private(set) var isDragging = false

    /// 进入拖拽状态：冻结定时器和状态变更
    func beginDrag() {
        isDragging = true
        idleTimer?.cancel()
        sleepTimer?.cancel()
        returnTimer?.cancel()
        currentState = .dragging
    }

    /// 结束拖拽状态：解冻并恢复到当前 session 的实际状态
    func endDrag() {
        isDragging = false
        // 从活跃 session 的当前 phase 计算正确状态，而非使用拖拽前的快照
        if let sid = activeSessionId, let session = sessions[sid] {
            currentState = stateForPhase(session.phase)
        } else {
            currentState = .idle
        }
        resetTimers()
    }

    /// 直接设置状态（外部控制用，拖拽期间被阻止）
    func overrideState(_ state: NotchikkoState) {
        guard !isDragging else { return }
        currentState = state
    }

    /// 缓存 session 匹配到的终端信息
    func setTerminalMatch(_ match: TerminalMatch, for sessionId: String) {
        sessions[sessionId]?.matchedTerminal = match
    }

    /// 更新 session 的终端 PID
    func setTerminalPid(_ pid: Int, for sessionId: String) {
        guard sessions[sessionId]?.terminalPid == nil else { return }
        sessions[sessionId]?.terminalPid = pid
    }

    /// 更新 session 的终端 tty
    func setTerminalTty(_ tty: String, for sessionId: String) {
        guard sessions[sessionId]?.terminalTty == nil else { return }
        sessions[sessionId]?.terminalTty = tty
    }

    func setPidChain(_ chain: [Int], for sessionId: String) {
        guard sessions[sessionId]?.pidChain == nil else { return }
        sessions[sessionId]?.pidChain = chain
    }

    /// 更新 session 的 bypass 模式
    func setBypassMode(_ bypass: Bool, for sessionId: String) {
        sessions[sessionId]?.isBypassMode = bypass
    }

    // MARK: - 内部

    /// 确保 session 存在，不存在则自动创建
    /// 最大 session 数量，超过时淘汰最旧的已结束 session
    private static let maxSessions = 32

    private func ensureSession(_ event: AgentEvent) {
        let sid = sessionIdOf(event)
        if case .sessionEnd = event { return }
        if sessions[sid] != nil { return }

        // 超过上限时淘汰最旧的 ended session，再淘汰最旧的非活跃 session
        if sessions.count >= Self.maxSessions {
            evictOldestSession()
        }

        // 从 sessionStart 中提取 cwd、source、terminalPid
        var cwd = ""
        var source = "unknown"
        var tPid: Int? = nil
        var pChain: [Int]?
        if case .sessionStart(_, let c, let s, let tp, let pc) = event {
            cwd = c
            source = s
            tPid = tp
            pChain = pc
        }

        sessions[sid] = SessionInfo(
            id: sid, cwd: cwd, source: source,
            lastEvent: Date(), phase: .waitingForInput,
            terminalPid: tPid, pidChain: pChain
        )
        Log("Auto-created session \(sid.prefix(8)), total: \(sessions.count)", tag: "Session")
    }

    private func evictOldestSession() {
        // 优先淘汰已结束的 session
        if let oldest = sessions.values.filter({ $0.phase == .ended }).min(by: { $0.lastEvent < $1.lastEvent }) {
            sessions.removeValue(forKey: oldest.id)
            return
        }
        // 没有 ended session，淘汰最旧的 idle session
        if let oldest = sessions.values.filter({ $0.phase == .waitingForInput }).min(by: { $0.lastEvent < $1.lastEvent }) {
            sessions.removeValue(forKey: oldest.id)
        }
    }

    private func sessionIdOf(_ event: AgentEvent) -> String {
        switch event {
        case .sessionStart(let sid, _, _, _, _): return sid
        case .sessionEnd(let sid): return sid
        case .prompt(let sid, _): return sid
        case .toolUse(let sid, _, _): return sid
        case .notification(let sid, _): return sid
        case .compact(let sid): return sid
        case .stop(let sid): return sid
        case .error(let sid, _): return sid
        }
    }

    private func transition(to newState: NotchikkoState) {
        guard !isDragging else { return }
        let oldState = currentState
        currentState = newState
        if oldState != newState {
            SoundManager.shared.play(for: newState.soundKey)
        }
    }

    private func resetTimers() {
        idleTimer?.cancel()
        sleepTimer?.cancel()

        idleTimer = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            transition(to: .idle)
        }

        sleepTimer = Task {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            transition(to: .sleeping)
        }
    }

    private func scheduleReturn(to state: NotchikkoState, delay: TimeInterval) {
        returnTimer?.cancel()
        returnTimer = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !isDragging else { return }
            currentState = state
        }
    }

    /// 庆祝完后自动切换到下一个活跃 session
    private func scheduleAutoSwitch(from sid: String, delay: TimeInterval) {
        returnTimer?.cancel()
        returnTimer = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, !isDragging else { return }

            // 如果绑定的就是这个 session，自动解绑
            if pinnedSessionId == sid {
                pinnedSessionId = nil
            }

            // 切换到下一个活跃 session 的状态
            if let nextId = activeSessionId, let next = sessions[nextId] {
                currentState = stateForPhase(next.phase)
                emitSessionDanmaku(next)
            } else {
                currentState = .idle
            }
        }
    }

    // MARK: - 弹幕辅助

    private func emitSessionDanmaku(_ session: SessionInfo) {
        let name = session.cwdName.isEmpty
            ? CLIHookConfig.metadata(for: session.source).displayName
            : session.cwdName
        danmakuCounter += 1
        danmakuSessionEvent = (danmakuCounter, name)
    }
}
