import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchPanel: NotchPanel?
    private var geometry: NotchGeometry?
    private var currentScreen: NSScreen?
    private let sessionManager = SessionManager()
    private var adapter: ClaudeCodeAdapter?
    private let dragController = DragController()
    private let menuBarManager = MenuBarManager()
    private var approvalManager: ApprovalManager?
    private var approvalPanelCoordinator: ApprovalPanelCoordinator?
    private var settingsWindow: NSWindow?
    private let terminalJumper = TerminalJumper()
    private let updateManager = UpdateManager()
    private var hotkeyBridge: ApprovalHotkeyBridge?
    private let transcriptPoller = TranscriptPoller()
    private let processDiscovery = ProcessDiscovery()
    private let hookOnboarding = HookOnboardingCoordinator()

    private var screenObserver: NSObjectProtocol?
    private var prefsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 忽略 SIGPIPE：写入已断开的 socket 时不要杀进程
        signal(SIGPIPE, SIG_IGN)

        NSApplication.shared.setActivationPolicy(.accessory)
        setupMenuBar()
        setupNotchWindow(on: NSScreen.main)
        startAgentListening()
        observeScreenChanges()
        hookOnboarding.promptIfNeeded()
        updateManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = prefsObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        dragController.teardown()
        hotkeyBridge?.deactivate()
        transcriptPoller.stop()
        processDiscovery.stop()
        // 关闭 socket server + finish event stream
        adapter?.socketServerRef.stop()
        // 把排队中的日志刷到磁盘，防止最后 N 行丢失
        FileLogger.shared.flush()
    }

    private func setupMenuBar() {
        menuBarManager.setup(sessionManager: sessionManager)

        menuBarManager.onSwitchScreen = { [weak self] screen in
            self?.setupNotchWindow(on: screen)
        }

        menuBarManager.onOpenSettings = { [weak self] in
            self?.openSettingsWindow()
        }

        menuBarManager.onJumpToSession = { [weak self] sessionId in
            guard let self, let session = self.sessionManager.sessions[sessionId] else { return }
            self.terminalJumper.jumpToSession(session: session)
        }

        menuBarManager.onRemoveSession = { [weak self] sessionId in
            // sessionManager.onSessionRemoved 回调会负责调 approvalManager.cleanupSession
            self?.sessionManager.removeSession(sessionId)
        }

        menuBarManager.onCheckForUpdates = { [weak self] in
            self?.updateManager.checkForUpdates()
        }

        menuBarManager.onQuit = {
            NSApp.terminate(nil)
        }
    }

    private func refreshNotchWindow() {
        // 拖拽期间不重建窗口，避免产生重复 panel
        guard !sessionManager.isDragging else { return }
        // 如果当前屏幕已断开（不在 screens 列表中），回退到主屏幕
        let target: NSScreen? = if let cur = currentScreen, NSScreen.screens.contains(cur) {
            cur
        } else {
            NSScreen.main
        }
        setupNotchWindow(on: target)
    }

    private func setupNotchWindow(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        self.currentScreen = screen
        menuBarManager.currentScreen = screen

        dragController.teardown()
        notchPanel?.close()
        notchPanel = nil

        let mode = PreferencesStore.shared.preferences.notchDetectionMode
        let geo = NotchGeometry(screen: screen, notchDetectionMode: mode)
        self.geometry = geo

        let panel = NotchPanel(frame: geo.panelFrame)
        panel.treatAsNotched = geo.hasPhysicalNotch
        // 强制设置 frame，防止系统自动调整位置
        panel.setFrame(geo.panelFrame, display: false)

        let petSize = 80 * PreferencesStore.shared.preferences.petScale
        let contentView = NotchContentView(
            notchHeight: geo.hiddenNotchHeight,
            sessionManager: sessionManager,
            petSize: petSize
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let hitTestView = NotchHitTestView()
        hitTestView.translatesAutoresizingMaskIntoConstraints = false
        hitTestView.addSubview(hostingView)

        // 宠物悬浮检测区域（view 本地坐标）
        let padding: CGFloat = 20
        hitTestView.petLocalRect = NSRect(
            x: geo.panelFrame.width / 2 - petSize / 2 - padding,
            y: geo.panelFrame.height - geo.hiddenNotchHeight - petSize - padding,
            width: petSize + padding * 2,
            height: petSize + padding * 2
        )
        hitTestView.onPetHover = { [weak self] in
            self?.approvalPanelCoordinator?.restoreHidden()
        }

        panel.contentView = hitTestView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: hitTestView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: hitTestView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: hitTestView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: hitTestView.bottomAnchor),
        ])

        panel.orderFrontRegardless()
        self.notchPanel = panel

        // 拖拽
        dragController.setup(panel: panel, homeFrame: geo.panelFrame,
                             notchHeight: geo.hiddenNotchHeight, petSize: petSize)
        dragController.onRightClick = { [weak self] screenPoint in
            guard let self, let panel = self.notchPanel else { return }
            self.menuBarManager.buildMenu()
            let localPoint = panel.convertPoint(fromScreen: screenPoint)
            self.menuBarManager.showContextMenu(in: panel, at: localPoint)
        }

        dragController.onClick = { [weak self] in
            guard let self else { return }
            // 优先活跃 session，fallback 到最近的任意 session（含已结束的）
            let session: SessionManager.SessionInfo? = {
                if let sid = self.sessionManager.activeSessionId,
                   let s = self.sessionManager.sessions[sid] { return s }
                return self.sessionManager.sessions.values
                    .max(by: { $0.lastEvent < $1.lastEvent })
            }()
            guard let session else {
                Log("Click: no session", tag: "App")
                return
            }
            Log("Click: sid=\(session.id.prefix(8)), cwd=\(session.cwdName), pid=\(session.terminalPid ?? -1), tty=\(session.terminalTty ?? "nil")", tag: "App")
            self.terminalJumper.jumpToSession(session: session)
        }

        dragController.onDragStart = { [weak self] in
            guard let self else { return }
            self.sessionManager.beginDrag()
        }
        dragController.onDragEnd = { [weak self] targetScreen in
            guard let self else { return }

            let landingScreen = targetScreen ?? self.currentScreen ?? NSScreen.main
            guard let landingScreen else { return }
            let isSameScreen = (landingScreen == self.currentScreen)

            if isSameScreen {
                // 同屏：先飞回原位，动画完成后再解冻状态
                // 避免 endDrag 触发的状态变化在动画期间干扰 panel frame
                guard let geo = self.geometry else { return }
                self.dragController.animateToFrame(geo.panelFrame) {
                    self.sessionManager.endDrag()
                }
            } else {
                // 跨屏：解冻状态，重建到目标屏幕
                self.sessionManager.endDrag()
                self.setupNotchWindow(on: landingScreen)
            }
        }
    }

    private func openSettingsWindow() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsWindowView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    private func startAgentListening() {
        let adapter = ClaudeCodeAdapter()
        self.adapter = adapter

        let approval = ApprovalManager(socketServer: adapter.socketServerRef)
        self.approvalManager = approval

        wireApprovalInfrastructure(adapter: adapter, approval: approval)
        wireSocketApproval(adapter: adapter, approval: approval)
        wireAdapterMetadata(adapter: adapter)
        wireDetectionFallbacks()

        Task { @MainActor in
            try? await adapter.start()
            for await event in adapter.eventStream {
                handleAgentEvent(event)
            }
        }
    }

    /// 1. 搭建审批基础设施：approval manager → bridge → panel coordinator + 3 个卡片生命周期回调
    private func wireApprovalInfrastructure(adapter: ClaudeCodeAdapter, approval: ApprovalManager) {
        // 终端匹配缓存回调
        terminalJumper.onTerminalMatched = { [weak self] sessionId, match in
            self?.sessionManager.setTerminalMatch(match, for: sessionId)
        }

        // Session 被移除（菜单关闭 / LRU 淘汰）时同步清理 approval 侧 session 级状态
        sessionManager.onSessionRemoved = { [weak approval] sessionId in
            approval?.cleanupSession(sessionId)
        }

        // 热键桥接（Cmd+Y/N 到 approve/deny 路由，仅在有阻塞式卡片时激活）
        hotkeyBridge = ApprovalHotkeyBridge(approvalManager: approval)

        // 审批面板 coordinator（NSPanel 全生命周期 + 动画）
        approvalPanelCoordinator = ApprovalPanelCoordinator(
            sessionManager: sessionManager,
            terminalJumper: terminalJumper,
            approvalManager: approval,
            geometryProvider: { [weak self] in self?.geometry },
            currentScreenProvider: { [weak self] in self?.currentScreen }
        )

        // 卡片移除回调
        approval.onCardDismissed = { [weak self] requestId in
            self?.approvalPanelCoordinator?.remove(requestId: requestId)
            // 无剩余阻塞式卡片 → 解锁 approving 状态
            if !(self?.approvalManager?.pendingApprovals.values.contains(where: { !$0.requestId.isEmpty }) ?? false) {
                self?.sessionManager.endApproval()
            }
            self?.hotkeyBridge?.refresh()
        }
        approval.onAllCardsDismissed = { [weak self] in
            self?.approvalPanelCoordinator?.removeAll()
            self?.sessionManager.endApproval()
            self?.hotkeyBridge?.refresh()
        }
        approval.onCardVisibilityChanged = { [weak self] reqId, visible in
            self?.approvalPanelCoordinator?.animateVisibility(requestId: reqId, visible: visible)
        }
    }

    /// 2. Socket → approval 的审批请求/断连桥接
    private func wireSocketApproval(adapter: ClaudeCodeAdapter, approval: ApprovalManager) {
        // Hook 进程断开 → 自动关闭对应审批卡片（用户按 Esc 等场景）
        adapter.socketServerRef.onApprovalDisconnect = { [weak self] requestId in
            Log("Hook disconnected, dismissing card: \(requestId.prefix(8))", tag: "App")
            self?.approvalManager?.dismissOnDisconnect(requestId: requestId)
        }

        adapter.socketServerRef.onApprovalRequest = { [weak self] hookEvent in
            guard let self else { return }
            // 收到新审批请求 → 只清理该 session 的通知卡片，保留其他审批卡片
            let notifCards = approval.pendingApprovals.values.filter {
                $0.sessionId == hookEvent.sessionId && $0.isNotification
            }
            for card in notifCards {
                approval.closeCard(requestId: card.id)
            }
            let session = self.sessionManager.sessions[hookEvent.sessionId]

            // bypass 模式 或 审批卡片关闭 → 直接放行，不弹卡片
            // AskUserQuestion 不受 approvalCardEnabled 控制（它是问答，不是审批）
            let isAskUser = hookEvent.tool == "AskUserQuestion"
            let isSubagent = self.adapter?.isInSubagent(sessionId: hookEvent.sessionId) ?? false
            if session?.isBypassMode == true || (!isAskUser && !PreferencesStore.shared.preferences.approvalCardEnabled) {
                let reason = session?.isBypassMode == true ? "bypass mode" : "approvalCard disabled"
                Log("Approval auto-allowed (\(reason)): \(hookEvent.tool ?? "?")", tag: "App")
                let requestId = hookEvent.requestId ?? ""
                let response: [String: Any] = ["request_id": requestId, "decision": "allow"]
                if let data = try? JSONSerialization.data(withJSONObject: response) {
                    self.adapter?.socketServerRef.respond(requestId: requestId, json: data)
                }
                return
            }

            approval.handleApprovalRequest(from: hookEvent, session: session, isSubagent: isSubagent)
            let requestId = hookEvent.requestId ?? ""
            // 只有真的创建了卡片（非 autoApproved session 的直通）才切换动画
            // subagent 审批也不切宠物动画（避免跳来跳去）
            if let request = approval.pendingApprovals[requestId] {
                if !isSubagent {
                    self.sessionManager.overrideState(.approving)
                }
                self.approvalPanelCoordinator?.show(request: request)
            }
            self.hotkeyBridge?.refresh()
        }
    }

    /// 3. 每个 hook 事件都可能携带的终端 PID/tty/pidChain/permissionMode 更新
    private func wireAdapterMetadata(adapter: ClaudeCodeAdapter) {
        adapter.onTerminalPidUpdate = { [weak self] sessionId, pid in
            self?.sessionManager.setTerminalPid(pid, for: sessionId)
        }
        adapter.onTerminalTtyUpdate = { [weak self] sessionId, tty in
            self?.sessionManager.setTerminalTty(tty, for: sessionId)
        }
        adapter.onPidChainUpdate = { [weak self] sessionId, chain in
            self?.sessionManager.setPidChain(chain, for: sessionId)
        }
        adapter.onPermissionModeUpdate = { [weak self] sessionId, mode in
            self?.sessionManager.setBypassMode(mode == "bypassPermissions", for: sessionId)
        }
    }

    /// 4. 无 hook 时的兜底 session 发现：JSONL 转录轮询 + ps 进程扫描
    private func wireDetectionFallbacks() {
        transcriptPoller.onEvent = { [weak self] event in
            self?.sessionManager.handleEvent(event)
        }
        transcriptPoller.onSessionDiscovered = { [weak self] sessionId in
            // handleEvent 创建的新 session 默认是 .hook，将其标记为 .transcript
            self?.sessionManager.setDetection(.transcript, for: sessionId)
        }
        transcriptPoller.start()

        processDiscovery.onProcessFound = { [weak self] sessionId, source, pid in
            guard let self else { return }
            // discovered session ID 使用 "discovered-" 前缀，不与 hook UUID 冲突
            self.sessionManager.handleEvent(.sessionStart(
                sessionId: sessionId, cwd: "", source: source,
                terminalPid: nil, pidChain: nil
            ))
            self.sessionManager.setDetection(.discovered, for: sessionId)
        }
        processDiscovery.onProcessExited = { [weak self] sessionId in
            self?.sessionManager.handleEvent(.sessionEnd(sessionId: sessionId))
        }
        processDiscovery.start()
    }

    /// 5. adapter.eventStream 每个 AgentEvent 到达时执行：session 更新 + 跨模块同步 + 通知卡弹出决策
    private func handleAgentEvent(_ event: AgentEvent) {
        sessionManager.handleEvent(event)

        // Hook 事件到达 → 升级对应 session 为 hook 来源，合并 transcript session
        sessionManager.upgradeDetection(.hook, for: event.sessionId)
        transcriptPoller.mergeWithHookSession(event.sessionId)
        // 同步 hook session IDs 给 pollers（避免重复发现）
        transcriptPoller.hookSessionIds = sessionManager.hookSessionIds
        processDiscovery.hookSessionIds = sessionManager.hookSessionIds

        let sid = event.sessionId
        approvalManager?.onSessionEvent(sessionId: sid)

        // 用户在终端操作了（新 prompt / 任务结束）→ 自动关闭过期审批卡片
        switch event {
        case .prompt, .stop, .sessionEnd:
            approvalManager?.dismissStaleApprovals(for: sid)
        default: break
        }

        // 防御性清理：无任何待审批卡片时解除 approving 锁定
        if approvalManager?.pendingApprovals.isEmpty == true,
           sessionManager.isApproving {
            sessionManager.endApproval()
        }

        // Session 结束 → 清理会话级审批状态 + bypass flag
        if case .sessionEnd(let endSid) = event {
            approvalManager?.cleanupSession(endSid)
        }

        // Elicitation / AskUserQuestion / PermissionRequest → 弹通知卡片
        if case .notification(let sid, let msg, let detail) = event {
            showNotificationCardIfNeeded(sessionId: sid, message: msg, detail: detail)
        }
    }

    /// 决定是否为 .notification 事件弹出非阻塞通知卡片。
    /// 规则：
    /// 1. 纯 Notification（空 msg）和未知事件 → 不弹
    /// 2. PermissionRequest + bypass on → 不弹
    /// 3. 过时（session 已结束、或到达前是 happy/sleeping）→ 不弹
    /// 4. Elicitation / AskUserQuestion → 始终弹（不受 approvalCardEnabled 影响）
    /// 5. PermissionRequest (non-bypass) → 受 approvalCardEnabled 控制
    private func showNotificationCardIfNeeded(sessionId sid: String, message msg: String, detail: String) {
        let session = sessionManager.sessions[sid]
        let isBypass = session?.isBypassMode ?? false
        let prevState = sessionManager.previousState

        let needsCard: Bool = {
            guard msg == "Elicitation" || msg == "AskUserQuestion"
                    || msg == "PermissionRequest" else { return false }
            if isBypass && msg == "PermissionRequest" { return false }
            if msg == "PermissionRequest"
                && !PreferencesStore.shared.preferences.approvalCardEnabled { return false }
            if session == nil || session?.phase == .ended { return false }
            if prevState == .happy || prevState == .sleeping { return false }
            return true
        }()
        guard needsCard else { return }

        let notifId = UUID().uuidString
        let request = ApprovalManager.ApprovalRequest(
            id: notifId,
            requestId: "",
            source: session?.source ?? "unknown",
            tool: msg,
            input: detail,
            sessionId: sid,
            cwdName: session?.cwdName ?? "",
            terminalName: session?.matchedTerminal?.appName ?? "",
            timestamp: Date()
        )
        approvalManager?.addNotification(request)

        // AskUserQuestion 消抖：PreToolUse 先到，PermissionRequest ~0.5s 后到
        // 延迟 1s 出卡片，如果期间 PermissionRequest 到达并替换了通知卡，panel 就不弹了
        if msg == "AskUserQuestion" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard self.approvalManager?.pendingApprovals[notifId] != nil else { return }
                self.approvalPanelCoordinator?.show(request: request)
            }
        } else {
            approvalPanelCoordinator?.show(request: request)
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNotchWindow()
        }

        prefsObserver = NotificationCenter.default.addObserver(
            forName: PreferencesStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNotchWindow()
        }
    }
}

