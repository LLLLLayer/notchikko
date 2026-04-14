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
    private var approvalPanels: [String: NSPanel] = [:]       // requestId → panel
    private var cardFinalFrames: [String: NSRect] = [:]      // requestId → 展开后的目标 frame
    private let terminalJumper = TerminalJumper()
    private let updateManager = UpdateManager()

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
        showHookInstallPromptIfNeeded()
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
            self?.restoreHiddenApprovalCards()
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
            // 无剩余阻塞式卡片 → 解锁 approving 状态
            if !(self?.approvalManager?.pendingApprovals.values.contains(where: { !$0.requestId.isEmpty }) ?? false) {
                self?.sessionManager.endApproval()
            }
        }
        approval.onAllCardsDismissed = { [weak self] in
            self?.removeAllApprovalPanels()
            self?.sessionManager.endApproval()
        }

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
            // subagent 审批不切换宠物动画（避免跳来跳去）
            if !isSubagent {
                self.sessionManager.overrideState(.approving)
            }
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

                // 收到后续事件 → 清理该 session 的通知卡片（保留阻塞式审批卡）
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

                // 用户在终端操作了（新 prompt / 任务结束）→ 自动关闭过期审批卡片
                switch event {
                case .prompt, .stop, .sessionEnd:
                    approvalManager?.dismissStaleApprovals(for: sid)
                default: break
                }

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

                        // AskUserQuestion 消抖：PreToolUse 先到，PermissionRequest ~0.5s 后到
                        // 延迟 1s 出卡片，如果期间 PermissionRequest 到达并替换了通知卡，panel 就不弹了
                        if msg == "AskUserQuestion" {
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(1))
                                guard self.approvalManager?.pendingApprovals[notifId] != nil else { return }
                                self.showApprovalPanel(for: request)
                            }
                        } else {
                            showApprovalPanel(for: request)
                        }
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

        // 气泡尾巴从宠物底部探出，微量重叠确保视觉连接
        let petSize = 80 * PreferencesStore.shared.preferences.petScale
        let stackIndex = min(CGFloat(approvalPanels.count), 5)
        let cardX = screen.frame.midX - cardWidth / 2
        let petBottom = screen.frame.maxY - geo.notchSize.height - petSize
        let overlap: CGFloat = 40
        let finalY = petBottom - cardHeight + overlap - stackIndex * Self.cardStackOffset
        let finalFrame = NSRect(x: cardX, y: finalY, width: cardWidth, height: cardHeight)

        // 初始位置 = 最终位置（透明），动画只做滑动+淡入
        let startY = finalY + cardHeight * 0.4  // 从偏上方（靠近宠物）开始
        let panel = NSPanel(
            contentRect: NSRect(x: cardX, y: startY, width: cardWidth, height: cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 层级低于宠物（mainMenu+3），卡片视觉上在宠物背后
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.hasShadow = false
        panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false

        let wrapper = ApprovalTrackingView(frame: panel.contentView?.bounds ?? panel.frame)
        wrapper.autoresizingMask = [.width, .height]
        wrapper.onMouseEnter = { [weak self] in
            self?.approvalManager?.onMouseEnter(requestId: reqId)
            self?.approvalPanels[reqId]?.alphaValue = 1.0
        }
        wrapper.onMouseExit = { [weak self] in
            self?.approvalManager?.onMouseExit(requestId: reqId)
        }
        wrapper.addSubview(hostingView)
        panel.contentView = wrapper

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])

        // 启用 layer 以支持退场缩放动画
        wrapper.wantsLayer = true

        panel.orderFrontRegardless()
        approvalPanels[reqId] = panel
        cardFinalFrames[reqId] = finalFrame

        // 滑入 + 淡入（入场缩放由 SwiftUI scaleEffect 处理，避免动画系统冲突）
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1.0
        })

        // 监听 isVisible 变化 → 滑动+淡入淡出
        let panelRef = panel
        Task { @MainActor in
            var lastVisible = true
            while approvalPanels[reqId] != nil {
                try? await Task.sleep(for: .milliseconds(300))
                let visible = approval.pendingApprovals[reqId]?.isVisible ?? false
                if visible != lastVisible {
                    lastVisible = visible
                    let targetY = visible ? finalFrame.origin.y : finalFrame.origin.y + cardHeight * 0.4
                    let targetFrame = NSRect(x: finalFrame.origin.x, y: targetY,
                                             width: finalFrame.width, height: finalFrame.height)
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = visible ? 0.25 : 0.2
                        ctx.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
                        panelRef.animator().setFrame(targetFrame, display: true)
                        panelRef.animator().alphaValue = visible ? 1.0 : 0.0
                    }, completionHandler: {})
                }
            }
        }
    }

    /// 鼠标悬浮在宠物上 → 恢复所有隐藏的审批卡片（滑下+淡入）
    private func restoreHiddenApprovalCards() {
        guard let approval = approvalManager else { return }
        approval.restoreAllHiddenCards()
        for (reqId, finalFrame) in cardFinalFrames {
            guard let panel = approvalPanels[reqId] else { continue }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(finalFrame, display: true)
                panel.animator().alphaValue = 1.0
            })
        }
    }

    /// 移除指定 requestId 的审批面板（滑上+淡出再关闭）
    private func removeApprovalPanel(requestId: String) {
        guard let panel = approvalPanels.removeValue(forKey: requestId) else { return }
        let finalFrame = cardFinalFrames.removeValue(forKey: requestId)

        let hideY = (finalFrame?.origin.y ?? panel.frame.origin.y) + panel.frame.height * 0.4
        var hiddenFrame = panel.frame
        hiddenFrame.origin.y = hideY

        // 滑出 + 淡出 + 缩小（display:false 避免和 layer 缩放动画冲突）
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(hiddenFrame, display: false)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.close()
        })
        let scaleOut = CABasicAnimation(keyPath: "transform")
        scaleOut.fromValue = CATransform3DIdentity
        scaleOut.toValue = CATransform3DMakeScale(0.88, 0.88, 1.0)
        scaleOut.duration = 0.2
        scaleOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.contentView?.layer?.add(scaleOut, forKey: "scaleOut")
        panel.contentView?.layer?.transform = CATransform3DMakeScale(0.88, 0.88, 1.0)
    }

    /// 移除所有审批面板（Allow All 时）
    private func removeAllApprovalPanels() {
        for (reqId, _) in approvalPanels {
            removeApprovalPanel(requestId: reqId)
        }
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

// MARK: - 审批卡片鼠标追踪

private final class ApprovalTrackingView: NSView {
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }
}
