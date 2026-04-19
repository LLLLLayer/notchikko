import Foundation
import AppKit

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
    /// 弹幕事件：撸猫 combo，附带计数
    private(set) var danmakuPettingEvent: (id: Int, combo: Int) = (0, 0)
    private var danmakuCounter = 0

    /// nil = 自动跟踪最新活跃 session
    var pinnedSessionId: String? = nil

    private var idleTimer: Task<Void, Never>?
    private var sleepTimer: Task<Void, Never>?
    private var returnTimer: Task<Void, Never>?
    private var sessionCleanupTasks: [String: Task<Void, Never>] = [:]

    /// 有未解决错误的 session。`.error` 入 set，任何前进事件（prompt/tool/compact/stop）清除；
    /// 只有在 set 中 + `.sessionEnd` 到来时才播 error 声——代表报错真的终断了会话。
    private var sessionsWithUnresolvedError: Set<String> = []

    /// Session 被移除时触发（菜单关闭 / LRU 淘汰）。
    /// 订阅者应清理自己持有的 session 级状态（e.g. ApprovalManager.autoApprovedSessions）
    var onSessionRemoved: ((String) -> Void)?

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
        var tokenUsage: HookEvent.TokenUsage?  // Stop 事件携带的最终 token 用量
        var detection: SessionDetection = .hook  // 发现方式

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
            case .runningTool(let t): return t
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

    /// Session 发现方式（hook 优先级最高）
    enum SessionDetection: String {
        case hook         // 通过 CLI hook 连接（完整功能）
        case transcript   // 通过 JSONL 转录文件发现（只读，无审批/终端跳转）
        case discovered   // 通过进程扫描发现（最小信息，无状态）
    }

    // MARK: - 当前活跃 session

    /// 当前展示的 session（pinned 优先 → 正在工作的 → 最近活跃的）
    var activeSessionId: String? {
        if let pinned = pinnedSessionId, sessions[pinned] != nil,
           sessions[pinned]?.phase != .ended {
            return pinned
        }
        let alive = sessions.values.filter { $0.phase != .ended }
        // 优先选正在工作的 session（processing / runningTool / compacting）
        if let working = alive.filter({ $0.phase != .waitingForInput })
            .max(by: { $0.lastEvent < $1.lastEvent }) {
            return working.id
        }
        // 都在等待输入则选最近活跃的
        return alive.max(by: { $0.lastEvent < $1.lastEvent })?.id
    }

    /// 活跃 session 列表（供右键菜单用，按最近活跃排序）
    var activeSessions: [SessionInfo] {
        sessions.values
            .filter { $0.phase != .ended }
            .sorted { $0.lastEvent > $1.lastEvent }
    }

    // MARK: - Session 管理

    /// 手动移除 session（用户从菜单关闭）
    func removeSession(_ sessionId: String) {
        sessionCleanupTasks[sessionId]?.cancel()
        sessionCleanupTasks.removeValue(forKey: sessionId)
        guard sessions.removeValue(forKey: sessionId) != nil else { return }
        // 手动关闭 ≠ 错误导致的中断 → 丢弃错误标记（用户主动关，不播声）
        sessionsWithUnresolvedError.remove(sessionId)
        onSessionRemoved?(sessionId)
        if pinnedSessionId == sessionId {
            pinnedSessionId = nil
        }
        // 恢复到下一个 active session；审批进行中则 restoreActiveState 守住 .approving
        restoreActiveState(fallback: .sleeping)
    }

    // MARK: - 绑定切换

    func pinSession(_ sessionId: String?) {
        let prev = pinnedSessionId
        pinnedSessionId = sessionId
        Log("pinSession: \(prev?.prefix(8) ?? "nil") → \(sessionId?.prefix(8) ?? "nil")", tag: "Session")
        // 发弹幕（如果切到了具体 session）
        if let sid = activeSessionId, let session = sessions[sid] {
            emitSessionDanmaku(session)
        }
        // 切换绑定后，恢复到目标 session 的 phase；审批进行中则保持 .approving
        restoreActiveState(fallback: .sleeping)
    }

    // MARK: - 事件处理

    func handleEvent(_ event: AgentEvent) {
        previousState = currentState
        Log("handleEvent: \(event), active=\(activeSessionId?.prefix(8) ?? "nil"), state=\(currentState)", tag: "Session")
        let eventSessionId = event.sessionId

        // ensureSession 会为未知 sid 补一个占位；sessionStart 的"升级/重入"路径需要知道这次事件之前
        // 有没有已存在的 session，所以在 ensureSession 之前先快照
        let wasPreExisting = sessions[eventSessionId] != nil

        // 收到未知 session 的事件时自动创建（应对中途安装 hook 的场景）
        ensureSession(event)

        // 每个事件都可能携带 terminalPid，更新到 session（首次检测到时生效）
        if case .sessionStart(_, _, _, let tPid, _) = event, let tPid,
           sessions[eventSessionId]?.terminalPid == nil {
            sessions[eventSessionId]?.terminalPid = tPid
        }

        switch event {
        case .sessionStart(let sid, let cwd, let source, let terminalPid, let pidChain):
            if wasPreExisting, let existing = sessions[sid], existing.phase != .ended {
                // 同 sid 的升级（transcript → hook / CLI 重入）：保留 phase 与运行时积累
                // （lastPrompt / lastToolSummary / matchedTerminal / tokenUsage / detection 等），
                // 只刷新元信息。不播 session-start 音效、不发 Danmaku、不动 state——这不是新 session。
                //
                // Why: 之前无条件重建 SessionInfo 会把正在 processing / runningTool 的 session 瞬间
                // 压回 waitingForInput，后续 restoreActiveState() 会把动画拉回 idle，造成
                // "有思考中的 session，动画却是 idle"。
                var merged = SessionInfo(
                    id: sid,
                    cwd: cwd.isEmpty ? existing.cwd : cwd,
                    source: source,
                    lastEvent: Date(),
                    phase: existing.phase,
                    terminalPid: terminalPid ?? existing.terminalPid,
                    pidChain: pidChain ?? existing.pidChain
                )
                merged.lastPrompt = existing.lastPrompt
                merged.lastToolSummary = existing.lastToolSummary
                merged.matchedTerminal = existing.matchedTerminal
                merged.terminalTty = existing.terminalTty
                merged.isBypassMode = existing.isBypassMode
                merged.tokenUsage = existing.tokenUsage
                merged.detection = existing.detection
                sessions[sid] = merged
                Log("sessionStart merge: sid=\(sid.prefix(8)), kept phase=\(existing.phase)", tag: "Session")
            } else {
                // 真正的新 session（或之前 ended 的重启）
                let hadWorkingSession = sessions.values.contains {
                    $0.id != sid && $0.phase != .ended && $0.phase != .waitingForInput
                }
                sessions[sid] = SessionInfo(
                    id: sid, cwd: cwd, source: source,
                    lastEvent: Date(), phase: .waitingForInput,
                    terminalPid: terminalPid, pidChain: pidChain
                )
                SoundManager.shared.play(for: "session-start")
                emitSessionDanmaku(sessions[sid]!)
                // 只在没有其他工作中 session 时切到 idle，避免打断正在工作的 session
                if !hadWorkingSession {
                    resetTimers()
                    transition(to: .idle)
                }
            }

        case .prompt(let sid, let text):
            sessions[sid]?.phase = .processing
            sessions[sid]?.lastEvent = Date()
            if let text, !text.isEmpty {
                sessions[sid]?.lastPrompt = text
            }
            // 前进事件：清掉未解决错误标记（用户继续推进，错误不是终断性的）
            sessionsWithUnresolvedError.remove(sid)
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
                // 前进事件：清掉错误标记
                sessionsWithUnresolvedError.remove(sid)
                if sid == activeSessionId {
                    resetTimers()
                    transition(to: stateForTool(tool))
                    // 弹幕：所有工具都发射
                    danmakuCounter += 1
                    danmakuToolEvent = (danmakuCounter, tool)
                }
            case .post(let success):
                sessions[sid]?.lastEvent = Date()
                if !success {
                    // 工具失败：phase 回到 waiting（不再跑工具），resetTimers 才能切到 waiting 档 timer；
                    // 并标记为未解决错误，后续若 sessionEnd 到来则播声
                    sessions[sid]?.phase = .waitingForInput
                    sessionsWithUnresolvedError.insert(sid)
                }
                if sid == activeSessionId && !success {
                    resetTimers()
                    transition(to: .error)
                    scheduleReturn(to: .idle, delay: 5.0)
                }
            }

        case .stop(let sid, let usage):
            sessions[sid]?.phase = .waitingForInput
            sessions[sid]?.lastEvent = Date()
            if let usage { sessions[sid]?.tokenUsage = usage }
            // 正常停止 = 任务完成，清掉错误标记
            sessionsWithUnresolvedError.remove(sid)
            Log("Stop: sid=\(sid.prefix(8)), active=\(activeSessionId?.prefix(8) ?? "nil"), state=\(currentState)", tag: "Session")
            if sid == activeSessionId {
                resetTimers()
                transition(to: .happy)
                // 庆祝完后，如果绑定了这个 session 且有其他活跃 session，自动切换
                scheduleAutoSwitch(from: sid, delay: 3.0)
            }

        case .error(let sid, _):
            sessions[sid]?.lastEvent = Date()
            // phase 回到 waiting（工具/任务已中断），resetTimers 才能切到 waiting 档 timer
            sessions[sid]?.phase = .waitingForInput
            // 标记为未解决错误——视觉切到 .error 但不响，等 sessionEnd 到来再判断是否是终断
            sessionsWithUnresolvedError.insert(sid)
            if sid == activeSessionId {
                resetTimers()
                transition(to: .error)
                scheduleReturn(to: .idle, delay: 5.0)
            }

        case .compact(let sid):
            sessions[sid]?.phase = .compacting
            sessions[sid]?.lastEvent = Date()
            // 前进事件：清掉错误标记
            sessionsWithUnresolvedError.remove(sid)
            if sid == activeSessionId {
                resetTimers()
                transition(to: .sweeping)
            }

        case .sessionEnd(let sid):
            // 先判断是否有未解决错误——若有，这是"错误导致会话中断"的情况，播 error 声
            if sessionsWithUnresolvedError.remove(sid) != nil {
                SoundManager.shared.play(for: "error")
            }
            sessions[sid]?.phase = .ended
            // 如果绑定的 session 结束了，自动解绑
            if pinnedSessionId == sid {
                pinnedSessionId = nil
            }
            // 延迟移除，让菜单有时间看到 ended 状态
            sessionCleanupTasks[sid]?.cancel()
            sessionCleanupTasks[sid] = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                sessions.removeValue(forKey: sid)
                sessionCleanupTasks.removeValue(forKey: sid)
            }
            // 如果还有活跃 session，切换到它的状态并重置 timer
            if let nextActive = activeSessionId, let session = sessions[nextActive] {
                resetTimers()
                transition(to: stateForPhase(session.phase))
            } else if activeSessions.isEmpty {
                resetTimers()
                transition(to: .sleeping)
            }

        case .notification(_, let msg, let detail):
            // 阻塞式 PermissionRequest 走 onApprovalRequest 直通，这里只处理信息性通知。
            // PermissionRequest 升格为 .permissionRequest case，不再用字符串判等识别。
            //
            // Notification 对待：CLI 顶层 message 字段带文本时视为"agent 要 attention"。
            // Gemini CLI 这是唯一的 attention channel；Claude Code 也会在终端审批 fallback /
            // 等待用户输入时发。空 message 的 Notification 是心跳类噪音，忽略。
            let needsUserAction: Bool = {
                switch msg {
                case "Elicitation", "AskUserQuestion": return true
                case "Notification": return !detail.isEmpty
                default: return false
                }
            }()
            guard needsUserAction else { break }
            triggerApprovingState(forSession: event.sessionId)

        case .permissionRequest(let sid, _, _):
            // 非阻塞 PermissionRequest（hook 没生成 request_id）：approvalCard 关或 bypass 已让 hook 直通放行
            // 此处仅在 approvalCard 开 + 非 bypass 的边缘场景下转动画（理论上很少发生，因为 approvalCard 开
            // 时 hook 通常会走阻塞路径），其余情况静默
            let isBypass = sessions[sid]?.isBypassMode ?? false
            let approvalOn = PreferencesStore.shared.preferences.approvalCardEnabled
            guard !isBypass && approvalOn else { break }
            triggerApprovingState(forSession: sid)
        }
    }

    /// 切到 approving 视觉状态 + 标记 session 等待输入
    private func triggerApprovingState(forSession sid: String) {
        sessions[sid]?.lastEvent = Date()
        sessions[sid]?.phase = .waitingForInput
        if sid == activeSessionId {
            idleTimer?.cancel()
            sleepTimer?.cancel()
            currentState = .approving
            isApproving = true
            SoundManager.shared.play(for: "approving")
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

    /// 审批期间锁定 approving 状态，阻止其他事件切走动画
    private(set) var isApproving = false

    /// 撸 Notchikko 期间锁定 petting 状态，阻止其他事件切走动画。优先级低于 dragging/approving
    private(set) var isPetting = false

    /// 进入拖拽状态：冻结定时器和状态变更（优先级最高，petting 被打断）
    func beginDrag() {
        if isPetting { isPetting = false }
        isDragging = true
        idleTimer?.cancel()
        sleepTimer?.cancel()
        returnTimer?.cancel()
        currentState = .dragging
    }

    /// 结束拖拽状态：解冻并恢复到当前 session 的实际状态
    func endDrag() {
        isDragging = false
        restoreActiveState()
    }

    /// 进入撸猫状态：drag/approving 期间不允许进入
    func beginPetting() {
        guard !isDragging && !isApproving else { return }
        isPetting = true
        idleTimer?.cancel()
        sleepTimer?.cancel()
        returnTimer?.cancel()
        currentState = .petting
        SoundManager.shared.play(for: "petting")
    }

    /// 结束撸猫：解锁并恢复到 session 当前实际状态；combo 立即清零
    func endPetting() {
        guard isPetting else { return }
        isPetting = false
        pettingCombo = 0
        lastComboTime = nil
        restoreActiveState()
    }

    // MARK: - 撸猫 Combo

    private var pettingCombo: Int = 0
    private var lastComboTime: Date?
    private static let comboBaseThrottle: TimeInterval = 0.2        // 初始节流 200ms（黄金段 5Hz 响）
    private static let comboMaxThrottle: TimeInterval = 0.4         // 节流封顶 400ms（高连击仍有节奏）
    private static let comboThrottleGrowthStart: Int = 10           // combo > 10 之后节流才开始变长
    private static let comboThrottleGrowthPerCombo: TimeInterval = 0.03  // 每 +1 combo 节流 +30ms
    private static let maxComboVariants: Int = 8                    // sfx-petting-1..8
    /// 里程碑 combo — 这些特殊点用专门的 sfx-petting-milestone.wav 增加新鲜感
    private static let comboMilestones: Set<Int> = [10, 15, 20, 30, 50, 75, 100]

    /// 一次方向反转到达 — 递增 combo（带动态节流），播对应升调音 + 发弹幕
    /// 注意：combo 重置 = endPetting 时清零（中断即重来）
    func registerPettingCombo() {
        let now = Date()

        // 动态节流：combo 越高，间隔越长，避免高连击段响声疲惫
        let extraDelay = max(0, pettingCombo - Self.comboThrottleGrowthStart)
        let throttle = min(
            Self.comboBaseThrottle + Double(extraDelay) * Self.comboThrottleGrowthPerCombo,
            Self.comboMaxThrottle
        )
        if let last = lastComboTime, now.timeIntervalSince(last) < throttle {
            return
        }

        pettingCombo += 1
        lastComboTime = now

        // 里程碑 combo → 专门的 fanfare 音效；其他用 variant 升调
        let soundKey: String
        if Self.comboMilestones.contains(pettingCombo) {
            soundKey = "petting-milestone"
        } else {
            let variant = min(pettingCombo, Self.maxComboVariants)
            soundKey = "petting-\(variant)"
        }
        SoundManager.shared.play(for: soundKey, cooldownKey: "petting-\(pettingCombo)")

        danmakuCounter += 1
        danmakuPettingEvent = (danmakuCounter, pettingCombo)
    }

    /// 直接设置状态（外部控制用，拖拽 / 撸猫期间被阻止；approving 例外它本身就是审批入口）
    func overrideState(_ state: NotchikkoState) {
        guard !isDragging else { return }
        // approving 是来自审批的强制状态，可以打断撸猫
        if isPetting && state == .approving {
            isPetting = false
        }
        guard !isPetting else { return }
        currentState = state
        if state == .approving {
            isApproving = true
        }
    }

    /// 结束审批锁定：恢复到当前 session 的实际状态
    func endApproval() {
        guard isApproving else { return }
        isApproving = false
        restoreActiveState()
    }

    /// 从活跃 session 的当前 phase 恢复正确状态。
    /// 审批进行中则保持 `.approving`——drag/petting/session 切换结束时审批卡还没关，
    /// 此处不能让 Notchikko 脱离审批锁视觉。endApproval() 调用本函数时 isApproving 已被手动置 false，
    /// 所以那条路径不受影响。
    private func restoreActiveState(fallback: NotchikkoState = .idle) {
        if isApproving {
            currentState = .approving
            // 审批期间不重启 idle/sleep timer——approving 是用户输入等待态，由审批链路掌控
            return
        }
        if let sid = activeSessionId, let session = sessions[sid] {
            currentState = stateForPhase(session.phase)
        } else {
            currentState = fallback
        }
        resetTimers()
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

    /// 设置 session 的发现来源（不允许降级：hook > transcript > discovered）
    func setDetection(_ detection: SessionDetection, for sessionId: String) {
        guard let current = sessions[sessionId]?.detection else { return }
        let priority: [SessionDetection] = [.discovered, .transcript, .hook]
        guard let currentIdx = priority.firstIndex(of: current),
              let newIdx = priority.firstIndex(of: detection),
              newIdx >= currentIdx else { return }
        sessions[sessionId]?.detection = detection
    }

    /// 升级 session 的发现来源（discovered/transcript → hook 时调用）
    func upgradeDetection(_ detection: SessionDetection, for sessionId: String) {
        guard let current = sessions[sessionId]?.detection else { return }
        // 只允许升级：discovered → transcript → hook
        let priority: [SessionDetection] = [.discovered, .transcript, .hook]
        guard let currentIdx = priority.firstIndex(of: current),
              let newIdx = priority.firstIndex(of: detection),
              newIdx > currentIdx else { return }
        sessions[sessionId]?.detection = detection
        Log("Session \(sessionId.prefix(8)) upgraded: \(current) → \(detection)", tag: "Session")
    }

    /// 已通过 hook 连接的 session IDs
    var hookSessionIds: Set<String> {
        Set(sessions.values.filter { $0.detection == .hook }.map(\.id))
    }

    // MARK: - 内部

    /// 确保 session 存在，不存在则自动创建
    /// 最大 session 数量，超过时淘汰最旧的已结束 session
    private static let maxSessions = 32

    private func ensureSession(_ event: AgentEvent) {
        let sid = event.sessionId
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
        // 1. 优先淘汰已结束的 session
        if let oldest = sessions.values.filter({ $0.phase == .ended }).min(by: { $0.lastEvent < $1.lastEvent }) {
            sessions.removeValue(forKey: oldest.id)
            sessionsWithUnresolvedError.remove(oldest.id)
            onSessionRemoved?(oldest.id)
            return
        }
        // 2. 再淘汰最旧的 idle session
        if let oldest = sessions.values.filter({ $0.phase == .waitingForInput }).min(by: { $0.lastEvent < $1.lastEvent }) {
            sessions.removeValue(forKey: oldest.id)
            sessionsWithUnresolvedError.remove(oldest.id)
            onSessionRemoved?(oldest.id)
            return
        }
        // 3. 极端情况：全在 working。淘汰最旧的任意 session，避免 dict 突破上限。
        if let oldest = sessions.values.min(by: { $0.lastEvent < $1.lastEvent }) {
            Log("Evicting working session under pressure: \(oldest.id.prefix(8))", tag: "Session")
            sessions.removeValue(forKey: oldest.id)
            sessionsWithUnresolvedError.remove(oldest.id)
            onSessionRemoved?(oldest.id)
        }
    }


    private func transition(to newState: NotchikkoState) {
        guard !isDragging else { return }
        // active session 已结束 → approval 必然过期，强制解锁
        // Why: 防御 dismiss 链路漏调 endApproval 导致 isApproving 永久卡 true
        if newState == .happy && isApproving {
            isApproving = false
        }
        guard !isApproving else { return }
        guard !isPetting else { return }
        let oldState = currentState
        currentState = newState
        if oldState != newState {
            // .error 状态不在这里响——只在 .sessionEnd 时若 session 带未解决错误才响，
            // 避免任务中间某次失败（后续还能继续跑）就叮一声。
            if newState != .error {
                SoundManager.shared.play(for: newState.soundKey)
            }
        }
    }

    /// 重置所有 timer。timer 长度按 active session 的 phase 分流：
    ///
    /// - **waiting 阶段**（waitingForInput / ended / 无 active session）：60s → idle，120s → sleep。
    ///   这是"用户离开了桌子"的剧本——pet 逐渐安静。
    /// - **working 阶段**（processing / runningTool / compacting）：不挂 idle timer，600s → sleep。
    ///   Codex 的 hook 只对 Bash 触发（upstream 限制），一个纯 Edit/Write 阶段可能几分钟不发事件；
    ///   Claude Code 的长 Bash / 长 LLM 推理同理。短 idle timer 会把还活着的 session 误判为空闲。
    ///   600s sleep 仍保留作为"进程卡死 / 被 kill"的兜底。
    private func resetTimers() {
        idleTimer?.cancel()
        sleepTimer?.cancel()
        returnTimer?.cancel()

        let activePhase: SessionPhase? = activeSessionId.flatMap { sessions[$0]?.phase }
        let isWorking: Bool = {
            switch activePhase {
            case .processing, .runningTool, .compacting: return true
            case .waitingForInput, .ended, .none: return false
            }
        }()

        if isWorking {
            sleepTimer = Task {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                transition(to: .sleeping)
            }
            return
        }

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
            guard !Task.isCancelled else { return }
            transition(to: state)
        }
    }

    /// 庆祝完后自动切换到下一个活跃 session
    private func scheduleAutoSwitch(from sid: String, delay: TimeInterval) {
        returnTimer?.cancel()
        returnTimer = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }

            // 如果绑定的就是这个 session，自动解绑
            if pinnedSessionId == sid {
                pinnedSessionId = nil
            }

            // 切换到下一个活跃 session 的状态；重置 timer 以新 session 的 phase 为准，
            // 避免上一个 .stop 留下来的 60s/120s waiting timer 把新 session 的工作态踢回 idle。
            if let nextId = activeSessionId, let next = sessions[nextId] {
                transition(to: stateForPhase(next.phase))
                resetTimers()
                emitSessionDanmaku(next)
            } else {
                transition(to: .idle)
                resetTimers()
            }
        }
    }

    // MARK: - 弹幕辅助

    private func emitSessionDanmaku(_ session: SessionInfo) {
        // 只播报项目名，CLI 名称（如 "Claude Code"）不弹
        guard !session.cwdName.isEmpty else { return }
        danmakuCounter += 1
        danmakuSessionEvent = (danmakuCounter, session.cwdName)
    }
}
