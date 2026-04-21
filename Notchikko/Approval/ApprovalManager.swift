import Foundation

@MainActor @Observable
final class ApprovalManager {
    /// 所有待审批请求（requestId → request），每张卡片独立闭环
    private(set) var pendingApprovals: [String: ApprovalRequest] = [:]

    private var hideTimers: [String: Task<Void, Never>] = [:]
    private var staleTimers: [String: Task<Void, Never>] = [:]
    private weak var socketServer: SocketServer?

    /// 已设为"全部允许"的 session（session 维度，不持久化）
    private var autoApprovedSessions: Set<String> = []

    /// 卡片移除回调（AppDelegate 注入，用于关闭对应 NSPanel）
    var onCardDismissed: ((String) -> Void)?
    /// 全部移除回调（Allow All / Auto Approve 时）
    var onAllCardsDismissed: (() -> Void)?
    /// 卡片可见性变化回调（用于驱动滑入/淡出动画，替代 300ms 轮询）
    var onCardVisibilityChanged: ((String, Bool) -> Void)?

    struct ApprovalRequest: Identifiable {
        let id: String             // 同 requestId，用于卡片标识
        let requestId: String
        let source: String
        let tool: String
        let input: String
        let sessionId: String
        let cwdName: String
        let terminalName: String
        let timestamp: Date
        var isVisible: Bool = true
        /// 来自 subagent 的请求（标注用，不影响审批流程）
        var isSubagent: Bool = false

        /// AskUserQuestion 的结构化问题数据
        var questions: [Question] = []

        /// 通知类卡片（无 requestId，不阻塞 CLI）
        var isNotification: Bool { requestId.isEmpty }
        /// 是否是可交互的 AskUserQuestion（有 requestId + 有 questions）
        var isAskUser: Bool { !requestId.isEmpty && !questions.isEmpty }

        struct Question: Identifiable {
            let text: String
            let options: [String]      // option labels（description 暂未透出给 UI）
            /// 官方文档: multiSelect=true 时 value 需要用 ", " (逗号+空格) join 多个 label。
            let multiSelect: Bool
            var id: String { text }
        }
    }

    init(socketServer: SocketServer) {
        self.socketServer = socketServer
    }

    // MARK: - 请求处理

    func handleApprovalRequest(from hookEvent: HookEvent, session: SessionManager.SessionInfo?, isSubagent: Bool = false) {
        let requestId = hookEvent.requestId ?? ""
        Log("handleApproval: tool=\(hookEvent.tool ?? "?"), sid=\(hookEvent.sessionId.prefix(8)), reqId=\(requestId.prefix(8))", tag: "Approval")

        // 主路径补齐：新的 PermissionRequest 抵达 → 同 session 之前悬挂的阻塞卡必然作废
        // （用户已在终端对前一张做了决定：拒绝 → 此处是 Claude 重问；允许 → 已被 PostToolUse 路径清理过）
        // 关闭旧卡 fd 让它们的 hook 解除阻塞，dismiss 卡片
        let stale = pendingApprovals.values.filter {
            $0.sessionId == hookEvent.sessionId
                && !$0.requestId.isEmpty
                && !$0.isAskUser
                && $0.requestId != requestId
        }
        if !stale.isEmpty {
            Log("handleApproval: superseded by new request, closing \(stale.count) stale card(s)", tag: "Approval")
            for card in stale {
                socketServer?.closePending(requestId: card.requestId)
                dismiss(requestId: card.id)
            }
        }

        // 如果该 session 已设为"全部允许"，直接放行。
        // 带 bypass:true 是为了让 CLI 切到 bypassPermissions 模式后不再发 PermissionRequest
        // —— 如果当前请求是菜单触发 bypass 后的第一次请求，这次响应会把 CLI 推进 bypass 态；
        // 如果 CLI 已经在 bypass，下次不会再进这条路径。setMode 是幂等的，重发无副作用。
        if autoApprovedSessions.contains(hookEvent.sessionId) {
            let response: [String: Any] = [
                "request_id": requestId,
                "decision": "allow",
                "bypass": true,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: response) {
                socketServer?.respond(requestId: requestId, json: data)
            }
            SoundManager.shared.play(for: "nod")
            return
        }

        let toolInput = hookEvent.toolInput?.values.first.flatMap { value -> String? in
            if case .string(let s) = value { return s }
            return nil
        } ?? ""

        // 解析 AskUserQuestion 的结构化问题
        let questions: [ApprovalRequest.Question] = Self.parseQuestions(from: hookEvent.toolInput)

        // AskUserQuestion 显示问题文本，审批显示 tool input
        let displayInput: String
        if !questions.isEmpty {
            displayInput = questions.map { q in
                var lines = [q.text]
                lines += q.options.map { "  · \($0)" }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
        } else {
            displayInput = String(toolInput.prefix(500))
        }

        let request = ApprovalRequest(
            id: requestId.isEmpty ? UUID().uuidString : requestId,
            requestId: requestId,
            source: hookEvent.source ?? "unknown",
            tool: hookEvent.tool ?? "",
            input: displayInput,
            sessionId: hookEvent.sessionId,
            cwdName: session?.cwdName ?? "",
            terminalName: session?.matchedTerminal?.appName ?? "",
            timestamp: Date(),
            isSubagent: isSubagent,
            questions: questions
        )

        pendingApprovals[request.id] = request
        startHideTimer(for: request.id)
        if !request.isNotification {
            startStaleTimer(for: request.id)
        }
    }

    /// 添加通知类卡片（Elicitation / AskUserQuestion）
    func addNotification(_ request: ApprovalRequest) {
        Log("addNotification: tool=\(request.tool), sid=\(request.sessionId.prefix(8)), id=\(request.id.prefix(8))", tag: "Approval")
        pendingApprovals[request.id] = request
        startHideTimer(for: request.id)
        // 通知卡片兜底：60s 后自动清理（不阻塞 CLI，无需等 300s）
        let notifId = request.id
        staleTimers[notifId]?.cancel()
        staleTimers[notifId] = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            pendingApprovals.removeValue(forKey: notifId)
            cleanupTimers(for: notifId)
            onCardDismissed?(notifId)
        }
    }

    // MARK: - 审批操作（每个操作都指定 requestId）

    func approve(requestId: String) {
        Log("approve: \(requestId.prefix(8))", tag: "Approval")
        guard let req = pendingApprovals[requestId] else { return }
        let response: [String: Any] = [
            "request_id": req.requestId,
            "decision": "allow",
        ]
        sendResponse(response, for: req)
        dismiss(requestId: requestId)
        SoundManager.shared.play(for: "nod")
    }

    func deny(requestId: String) {
        Log("deny: \(requestId.prefix(8))", tag: "Approval")
        guard let req = pendingApprovals[requestId] else { return }
        let response: [String: Any] = [
            "request_id": req.requestId,
            "decision": "deny",
            "reason": "Denied by Notchikko",
        ]
        sendResponse(response, for: req)
        dismiss(requestId: requestId)
        SoundManager.shared.play(for: "shake")
    }

    /// 始终允许：放行当前请求 + 将该工具加入项目允许列表（settings.local.json）
    func alwaysAllowTool(requestId: String) {
        guard let req = pendingApprovals[requestId] else { return }
        Log("alwaysAllow: tool=\(req.tool), sid=\(req.sessionId.prefix(8))", tag: "Approval")

        // allow_tool 告诉 hook 脚本用 addRules 写入 settings.local.json
        let response: [String: Any] = [
            "request_id": req.requestId,
            "decision": "allow",
            "allow_tool": req.tool,
        ]
        sendResponse(response, for: req)
        dismiss(requestId: requestId)
        SoundManager.shared.play(for: "nod")
    }

    /// AskUserQuestion: 用户在卡片上为所有问题都选好了答案，一次性提交。
    ///
    /// `answers` 的 key 必须是 question 文本（严格匹配），value 是选中 option 的 label
    /// 字符串。multiSelect 题若选多个，调用方应已用 `", "`（逗号+空格）join 好，因为
    /// 官方文档明确要求这个格式——详见 ApprovalCardView 里的提交逻辑。
    ///
    /// 覆盖所有 req.questions 才算完整；若调用方漏了 key，Claude Code 会重新调
    /// AskUserQuestion 补齐剩余问题，从用户视角就是"卡片又弹出来"。所以 UI 侧必须
    /// 先确保 answers 字典覆盖完整（Submit 按钮在凑齐前置灰）。
    func answerAllQuestions(requestId: String, answers: [String: String]) {
        guard let req = pendingApprovals[requestId] else { return }
        Log("answerAllQuestions: n=\(answers.count), reqId=\(requestId.prefix(8))", tag: "Approval")

        let response: [String: Any] = [
            "request_id": req.requestId,
            "answers": answers,
        ]
        sendResponse(response, for: req)
        dismiss(requestId: requestId)
        SoundManager.shared.play(for: "nod")
    }

    /// 自动批准：放行所有待审批 + 立即开 bypassPermissions（会话级）。
    /// 供卡片上的 "Auto Approve" 按钮使用，内部委托给 `enableBypass(for:)`。
    func autoApproveSession(requestId: String) {
        guard let req = pendingApprovals[requestId] else { return }
        enableBypass(for: req.sessionId)
    }

    /// 会话是否已开启自动批准（菜单勾选 / 卡片"Auto Approve"之后为 true）。
    func isBypassed(_ sessionId: String) -> Bool {
        autoApprovedSessions.contains(sessionId)
    }

    /// 打开会话级自动批准。
    ///
    /// 行为：
    /// 1. 设置 app 侧 flag，后续 `handleApprovalRequest` 走快速放行（附带 `bypass: true`）。
    /// 2. 把当前同 session 所有阻塞式卡片一次性放行，首条响应带 `bypass: true`
    ///    把 CLI 推进 bypassPermissions 模式。
    ///
    /// 菜单"自动批准"项和卡片"Auto Approve"按钮都走这里。调用时可以没有任何
    /// 在途请求——这就是菜单路径的用法：flag 先置上，等下一次 PermissionRequest 到来
    /// 时由快速放行路径把 CLI 切到 bypass。
    func enableBypass(for sessionId: String) {
        Log("enableBypass: sid=\(sessionId.prefix(8))", tag: "Approval")
        autoApprovedSessions.insert(sessionId)

        var bypassSent = false
        var allIds: [String] = []
        for r in pendingApprovals.values where r.sessionId == sessionId {
            allIds.append(r.id)
            if !r.isNotification {
                var response: [String: Any] = [
                    "request_id": r.requestId,
                    "decision": "allow",
                ]
                if !bypassSent {
                    response["bypass"] = true
                    bypassSent = true
                }
                sendResponse(response, for: r)
            }
        }

        for id in allIds {
            cleanupTimers(for: id)
            pendingApprovals.removeValue(forKey: id)
            onCardDismissed?(id)
        }

        SoundManager.shared.play(for: "nod")
    }

    /// 关闭会话级自动批准。注意：CLI 侧一旦进入 bypassPermissions 模式，只能由用户在
    /// 终端用 `/permissions` 命令退出；这里只能停止 app 侧的自动放行，如果 CLI 之后
    /// 真的再发 PermissionRequest（通常不会，它已经 bypass 了），就会重新走卡片流程。
    func disableBypass(for sessionId: String) {
        guard autoApprovedSessions.contains(sessionId) else { return }
        Log("disableBypass: sid=\(sessionId.prefix(8))", tag: "Approval")
        autoApprovedSessions.remove(sessionId)
    }

    // MARK: - 热键查询

    /// 是否有待决的阻塞式审批（不含 AskUserQuestion 和通知卡）
    var hasPendingBlockingApproval: Bool {
        pendingApprovals.values.contains { !$0.requestId.isEmpty && !$0.isAskUser }
    }

    /// 最新的阻塞式审批卡片（热键作用目标）
    var mostRecentBlockingApproval: ApprovalRequest? {
        pendingApprovals.values
            .filter { !$0.requestId.isEmpty && !$0.isAskUser }
            .max(by: { $0.timestamp < $1.timestamp })
    }

    // MARK: - 卡片显示控制

    func onMouseEnter(requestId: String) {
        guard let req = pendingApprovals[requestId] else { return }
        // 阻塞式卡片：先确认对端 hook 仍活着，若已断开直接 dismiss 不再飘出
        if !req.requestId.isEmpty,
           socketServer?.isRequestAlive(requestId: req.requestId) == false {
            Log("onMouseEnter: hook gone, dismissing \(requestId.prefix(8))", tag: "Approval")
            dismiss(requestId: requestId)
            return
        }
        setVisibility(true, for: requestId)
        hideTimers[requestId]?.cancel()
        hideTimers[requestId] = nil
    }

    /// 统一可见性变更入口：去重后触发回调，驱动 NSPanel 动画
    private func setVisibility(_ visible: Bool, for requestId: String) {
        guard let current = pendingApprovals[requestId]?.isVisible, current != visible else { return }
        pendingApprovals[requestId]?.isVisible = visible
        onCardVisibilityChanged?(requestId, visible)
    }

    func onMouseExit(requestId: String) {
        guard pendingApprovals[requestId] != nil else { return }
        startHideTimer(for: requestId)
    }

    /// 恢复所有已隐藏的卡片（鼠标悬浮在 Notchikko 上时调用）
    func restoreAllHiddenCards() {
        for reqId in pendingApprovals.keys {
            guard pendingApprovals[reqId]?.isVisible == false else { continue }
            onMouseEnter(requestId: reqId)
        }
    }

    /// Session 结束时清理会话级状态
    func cleanupSession(_ sessionId: String) {
        autoApprovedSessions.remove(sessionId)
    }

    /// 工具已在外部被放行（用户走了 CLI 内置授权而非卡片）→ 同 session+tool 的阻塞卡片是僵尸
    /// 关闭 socket fd 让阻塞中的 hook 退出，再 dismiss 卡片
    func dismissStaleApprovals(for sessionId: String, tool: String) {
        let stale = pendingApprovals.values.filter {
            $0.sessionId == sessionId && $0.tool == tool && !$0.requestId.isEmpty && !$0.isAskUser
        }
        guard !stale.isEmpty else { return }
        Log("dismissStaleApprovals: sid=\(sessionId.prefix(8)), tool=\(tool), closing \(stale.count) stale card(s)", tag: "Approval")
        for card in stale {
            socketServer?.closePending(requestId: card.requestId)
            dismiss(requestId: card.id)
        }
    }

    /// 用户在终端操作了（新 prompt / stop），清理该 session 的过期审批卡片
    /// hook 连接可能已断开，只做 app 侧清理
    func dismissStaleApprovals(for sessionId: String) {
        let stale = pendingApprovals.values.filter {
            $0.sessionId == sessionId && !$0.requestId.isEmpty
        }
        guard !stale.isEmpty else { return }
        Log("dismissStaleApprovals: sid=\(sessionId.prefix(8)), closing \(stale.count) stale card(s)", tag: "Approval")
        for card in stale {
            socketServer?.closePending(requestId: card.requestId)
            dismiss(requestId: card.id)
        }
    }

    /// 收到后续事件 → 只清理通知卡片，保留阻塞式审批/AskUser 卡片
    /// 阻塞式卡片由用户操作或 staleTimer 清理
    func onSessionEvent(sessionId: String) {
        guard !pendingApprovals.isEmpty else { return }
        let toRemove = pendingApprovals.values.filter {
            $0.sessionId == sessionId && $0.requestId.isEmpty
        }.map { $0.id }
        if !toRemove.isEmpty {
            Log("onSessionEvent: sid=\(sessionId.prefix(8)), clearing \(toRemove.count) notification card(s)", tag: "Approval")
        }
        for id in toRemove {
            // 二次校验：确保不误删阻塞式审批卡片
            guard let card = pendingApprovals[id], card.requestId.isEmpty else {
                Log("onSessionEvent: SKIP non-notification card id=\(id.prefix(8))", tag: "Approval")
                continue
            }
            dismiss(requestId: id)
        }
    }

    // MARK: - Private

    /// 关闭指定卡片（关闭按钮 = deny 审批卡，直接关闭通知卡）
    /// Hook 断开时直接关闭卡片（不发送响应 — hook 已死）
    func dismissOnDisconnect(requestId: String) {
        guard pendingApprovals[requestId] != nil else { return }
        Log("dismissOnDisconnect: \(requestId.prefix(8))", tag: "Approval")
        dismiss(requestId: requestId)
    }

    func closeCard(requestId: String) {
        guard let req = pendingApprovals[requestId] else { return }
        if req.isNotification {
            dismiss(requestId: requestId)
        } else {
            deny(requestId: requestId)
        }
    }

    private func dismiss(requestId: String) {
        Log("dismiss: \(requestId.prefix(8)), remaining=\(pendingApprovals.count - 1)", tag: "Approval")
        cleanupTimers(for: requestId)
        pendingApprovals.removeValue(forKey: requestId)
        onCardDismissed?(requestId)
    }

    private func cleanupTimers(for requestId: String) {
        hideTimers[requestId]?.cancel()
        hideTimers.removeValue(forKey: requestId)
        staleTimers[requestId]?.cancel()
        staleTimers.removeValue(forKey: requestId)
    }

    /// Hook PermissionRequest timeout = 86400s (24h)。
    /// App 侧兜底清理，防止卡片永驻。
    private static let staleTimeout: TimeInterval = 86400

    private func startStaleTimer(for requestId: String) {
        staleTimers[requestId]?.cancel()
        staleTimers[requestId] = Task {
            try? await Task.sleep(for: .seconds(Self.staleTimeout))
            guard !Task.isCancelled else { return }
            // 超时：hook 侧已自动放行并关闭连接，app 侧也关闭对应 fd 防止泄漏
            if let req = pendingApprovals[requestId], !req.requestId.isEmpty {
                socketServer?.closePending(requestId: req.requestId)
            }
            pendingApprovals.removeValue(forKey: requestId)
            cleanupTimers(for: requestId)
            onCardDismissed?(requestId)
        }
    }

    private func startHideTimer(for requestId: String) {
        hideTimers[requestId]?.cancel()
        let delay = PreferencesStore.shared.preferences.approvalCardHideDelay
        guard delay > 0 else { return }
        hideTimers[requestId] = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            setVisibility(false, for: requestId)
        }
    }

    private func sendResponse(_ dict: [String: Any], for req: ApprovalRequest) {
        guard !req.requestId.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        socketServer?.respond(requestId: req.requestId, json: data)
    }

    // MARK: - Question Parsing

    /// 从 toolInput 解析 AskUserQuestion 的结构化问题
    static func parseQuestions(from toolInput: [String: AnyCodableValue]?) -> [ApprovalRequest.Question] {
        guard let toolInput else { return [] }

        // 单问题模式（遗留兼容）: { question: "...", options: [...] }
        if case .string(let q) = toolInput["question"] {
            var opts: [String] = []
            if case .array(let options) = toolInput["options"] {
                for opt in options {
                    if case .object(let d) = opt, case .string(let label) = d["label"] {
                        opts.append(label)
                    } else if case .string(let label) = opt {
                        opts.append(label)
                    }
                }
            }
            let multi: Bool = {
                if case .bool(let b) = toolInput["multiSelect"] { return b }
                return false
            }()
            if !opts.isEmpty { return [.init(text: q, options: opts, multiSelect: multi)] }
        }

        // 多问题模式（Claude Code AskUserQuestion 正常格式，1–4 个问题，每题 2–4 选项）:
        // { questions: [{ question, header?, multiSelect?, options: [{label, description?}] }] }
        guard case .array(let questions) = toolInput["questions"] else { return [] }
        var result: [ApprovalRequest.Question] = []
        for q in questions {
            guard case .object(let dict) = q,
                  case .string(let text) = dict["question"] else { continue }
            var opts: [String] = []
            if case .array(let options) = dict["options"] {
                for opt in options {
                    if case .object(let d) = opt, case .string(let label) = d["label"] {
                        opts.append(label)
                    }
                }
            }
            let multi: Bool = {
                if case .bool(let b) = dict["multiSelect"] { return b }
                return false
            }()
            if !opts.isEmpty {
                result.append(.init(text: text, options: opts, multiSelect: multi))
            }
        }
        return result
    }
}
