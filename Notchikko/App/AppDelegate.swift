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
    private var settingsWindow: NSWindow?
    private var approvalPanels: [String: NSPanel] = [:]  // requestId → panel
    private let terminalJumper = TerminalJumper()

    private var screenObserver: NSObjectProtocol?
    private var prefsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        setupMenuBar()
        setupNotchWindow(on: NSScreen.main)
        startAgentListening()
        observeScreenChanges()
        showHookInstallPromptIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = prefsObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        dragController.teardown()
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
            self?.sessionManager.removeSession(sessionId)
            self?.approvalManager?.cleanupSession(sessionId)
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

        // 终端匹配缓存回调
        terminalJumper.onTerminalMatched = { [weak self] sessionId, match in
            self?.sessionManager.setTerminalMatch(match, for: sessionId)
        }

        // 审批面板（受 Settings 开关控制）
        let approval = ApprovalManager(socketServer: adapter.socketServerRef)
        self.approvalManager = approval

        // 卡片移除回调
        approval.onCardDismissed = { [weak self] requestId in
            self?.removeApprovalPanel(requestId: requestId)
        }
        approval.onAllCardsDismissed = { [weak self] in
            self?.removeAllApprovalPanels()
        }

        adapter.socketServerRef.onApprovalRequest = { [weak self] hookEvent in
            guard let self else { return }
            // 收到新审批请求 → 先清理该 session 的旧卡片（通知卡片等）
            approval.onSessionEvent(sessionId: hookEvent.sessionId)
            let session = self.sessionManager.sessions[hookEvent.sessionId]

            // bypass 模式 或 审批卡片关闭 → 直接放行，不弹卡片
            // AskUserQuestion 不受 approvalCardEnabled 控制（它是问答，不是审批）
            let isAskUser = hookEvent.tool == "AskUserQuestion"
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

            approval.handleApprovalRequest(from: hookEvent, session: session)
            self.sessionManager.overrideState(.approving)
            let requestId = hookEvent.requestId ?? ""
            if let request = approval.pendingApprovals[requestId] {
                self.showApprovalPanel(for: request)
            }
        }

        // 终端 PID/tty 更新回调（每个 hook 事件都可能携带）
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

        Task {
            try? await adapter.start()
            for await event in adapter.eventStream {
                sessionManager.handleEvent(event)

                // 收到后续事件 → 说明 CLI 侧已处理完审批，自动关闭该 session 的卡片
                let sid: String = switch event {
                case .sessionStart(let s, _, _, _, _): s
                case .sessionEnd(let s): s
                case .prompt(let s, _): s
                case .toolUse(let s, _, _): s
                case .notification(let s, _, _): s
                case .compact(let s): s
                case .stop(let s, _): s
                case .error(let s, _): s
                }
                approvalManager?.onSessionEvent(sessionId: sid)

                // Session 结束 → 清理会话级审批状态 + bypass flag
                if case .sessionEnd(let endSid) = event {
                    approvalManager?.cleanupSession(endSid)
                }

                // Elicitation / AskUserQuestion / PermissionRequest → 弹通知卡片
                if case .notification(let sid, let msg, let detail) = event {
                    let session = sessionManager.sessions[sid]
                    let isBypass = session?.isBypassMode ?? false
                    let prevState = sessionManager.previousState

                    // 决定是否弹卡片：
                    // 1. 纯 Notification（空 msg）和未知事件 → 不弹
                    // 2. PermissionRequest + bypass on → 不弹
                    // 3. 过时（session 已结束、或到达前是 happy/sleeping）→ 不弹
                    // 4. Elicitation / AskUserQuestion → 始终弹（不受 approvalCardEnabled 影响）
                    // 5. PermissionRequest (non-bypass) → 受 approvalCardEnabled 控制
                    let needsCard: Bool = {
                        guard msg == "Elicitation" || msg == "AskUserQuestion"
                                || msg == "PermissionRequest" else { return false }
                        // bypass 模式下 PermissionRequest 不弹
                        if isBypass && msg == "PermissionRequest" { return false }
                        // PermissionRequest 受 approvalCardEnabled 控制
                        if msg == "PermissionRequest"
                            && !PreferencesStore.shared.preferences.approvalCardEnabled { return false }
                        // 过时检查
                        if session == nil || session?.phase == .ended { return false }
                        if prevState == .happy || prevState == .sleeping { return false }
                        return true
                    }()

                    if needsCard {
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
                        showApprovalPanel(for: request)
                    }
                }
            }
        }
    }

    // MARK: - 审批面板（叠加式，新卡片错位堆叠）

    /// 每张卡片的错位偏移量
    private static let cardStackOffset: CGFloat = 8

    private func showApprovalPanel(for request: ApprovalManager.ApprovalRequest) {
        guard let geo = geometry,
              let approval = approvalManager else { return }

        let reqId = request.id

        let cardView = ApprovalCardView(
            request: request,
            onDeny: {
                approval.deny(requestId: reqId)
            },
            onApprove: {
                approval.approve(requestId: reqId)
            },
            onAlwaysAllow: {
                approval.alwaysAllowTool(requestId: reqId)
            },
            onAutoApprove: {
                approval.autoApproveSession(requestId: reqId)
            },
            onAnswer: { questionText, answer in
                approval.answerQuestion(requestId: reqId, questionText: questionText, answer: answer)
            },
            onJump: { [weak self] in
                guard let self,
                      let session = self.sessionManager.sessions[request.sessionId] else { return }
                self.terminalJumper.jumpToSession(session: session)
            },
            onClose: {
                // 关闭按钮：审批卡 = deny，通知卡 = 直接关闭
                approval.closeCard(requestId: reqId)
            }
        )

        let hostingView = NSHostingView(rootView: cardView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let cardWidth: CGFloat = 340
        // 让 hostingView 计算实际高度，避免空白过多
        let fittingSize = hostingView.fittingSize
        let cardHeight: CGFloat = min(max(fittingSize.height, 60), 240)
        guard let screen = currentScreen ?? NSScreen.main else { return }

        // 卡片居中在宠物正下方，多张卡片向下堆叠
        let stackIndex = min(CGFloat(approvalPanels.count), 5)
        let cardX = screen.frame.midX - cardWidth / 2
        let petBottom = screen.frame.maxY - geo.notchSize.height - (80 * PreferencesStore.shared.preferences.petScale)
        let cardY = petBottom - cardHeight - 8 - stackIndex * Self.cardStackOffset

        let panel = NSPanel(
            contentRect: NSRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1 + approvalPanels.count)
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false

        let wrapper = NSView(frame: panel.contentView?.bounds ?? panel.frame)
        wrapper.autoresizingMask = [.width, .height]
        wrapper.addSubview(hostingView)
        panel.contentView = wrapper

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])

        panel.orderFrontRegardless()
        approvalPanels[reqId] = panel
    }

    /// 移除指定 requestId 的审批面板
    private func removeApprovalPanel(requestId: String) {
        guard let panel = approvalPanels.removeValue(forKey: requestId) else { return }
        panel.close()
    }

    /// 移除所有审批面板（Allow All 时）
    private func removeAllApprovalPanels() {
        for (_, panel) in approvalPanels {
            panel.close()
        }
        approvalPanels.removeAll()
    }

    // MARK: - 首次启动 Hook 安装引导

    private func showHookInstallPromptIfNeeded() {
        guard !PreferencesStore.shared.preferences.hasShownHookPrompt else { return }

        let installer = HookInstaller()
        // 检测哪些 CLI 已安装但未装 hook
        let uninstalledCLIs = HookInstaller.supportedCLIs.filter { cli in
            let settingsURL = URL(fileURLWithPath: NSString(string: cli.settingsPath).expandingTildeInPath)
            let cliExists = FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path)
            return cliExists && !installer.isInstalled(for: cli)
        }

        guard !uninstalledCLIs.isEmpty else {
            PreferencesStore.shared.preferences.hasShownHookPrompt = true
            return
        }

        // 延迟 1s 弹窗，等窗口就绪
        Task {
            try? await Task.sleep(for: .seconds(1))
            let names = uninstalledCLIs.map { "\($0.icon) \($0.displayName)" }.joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = String(localized: "hook_prompt.title")
            alert.informativeText = String(format: String(localized: "hook_prompt.message"), names)
            alert.addButton(withTitle: String(localized: "hook_prompt.install"))
            alert.addButton(withTitle: String(localized: "hook_prompt.later"))
            alert.alertStyle = .informational

            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()

            if response == .alertFirstButtonReturn {
                for cli in uninstalledCLIs {
                    do {
                        try installer.install(for: cli)
                        Log("Auto-installed hook for \(cli.displayName)", tag: "App")
                    } catch {
                        Log("Failed to install hook for \(cli.displayName): \(error)", tag: "App")
                    }
                }
            }

            PreferencesStore.shared.preferences.hasShownHookPrompt = true
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
