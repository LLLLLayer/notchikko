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
    private var approvalPanels: [NSPanel] = []
    private let terminalJumper = TerminalJumper()

    private var screenObserver: NSObjectProtocol?
    private var prefsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        setupMenuBar()
        setupNotchWindow(on: NSScreen.main)
        startAgentListening()
        observeScreenChanges()
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

        menuBarManager.onQuit = {
            NSApp.terminate(nil)
        }
    }

    private func refreshNotchWindow() {
        // 拖拽期间不重建窗口，���免产生重复 panel
        guard !sessionManager.isDragging else { return }
        setupNotchWindow(on: currentScreen)
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
            guard let sid = self.sessionManager.activeSessionId,
                  let session = self.sessionManager.sessions[sid] else {
                #if DEBUG
                print("[Click] no active session")
                #endif
                return
            }
            #if DEBUG
            print("[Click] sid=\(sid.prefix(8)), cwd=\(session.cwdName), terminalPid=\(session.terminalPid ?? -1)")
            #endif
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
                // 同屏：解冻状态（恢复为当前 session 实际 phase），同时飞回原位
                guard let geo = self.geometry else { return }
                self.sessionManager.endDrag()
                self.dragController.animateToFrame(geo.panelFrame) {}
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

        // 审批面板（受 Settings 开关控制）
        let approval = ApprovalManager(socketServer: adapter.socketServerRef)
        self.approvalManager = approval

        adapter.socketServerRef.onApprovalRequest = { [weak self] hookEvent in
            guard let self else { return }
            let session = self.sessionManager.sessions[hookEvent.sessionId]
            approval.handleApprovalRequest(from: hookEvent, session: session)
            self.sessionManager.overrideState(.approving)
            if PreferencesStore.shared.preferences.approvalCardEnabled {
                self.showApprovalPanel()
            }
        }

        // 终端 PID/tty 更新回调（每个 hook 事件都可能携带）
        adapter.onTerminalPidUpdate = { [weak self] sessionId, pid in
            self?.sessionManager.setTerminalPid(pid, for: sessionId)
        }
        adapter.onTerminalTtyUpdate = { [weak self] sessionId, tty in
            self?.sessionManager.setTerminalTty(tty, for: sessionId)
        }
        adapter.onPermissionModeUpdate = { [weak self] sessionId, mode in
            self?.sessionManager.setBypassMode(mode == "bypassPermissions", for: sessionId)
        }

        Task {
            try? await adapter.start()
            for await event in adapter.eventStream {
                sessionManager.handleEvent(event)

                // Elicitation/Notification → 也弹审批卡片
                if case .notification(let sid, let msg) = event,
                   PreferencesStore.shared.preferences.approvalCardEnabled {
                    let session = sessionManager.sessions[sid]
                    let isBypass = session?.isBypassMode ?? false
                    if !(isBypass && msg == "PermissionRequest") {
                        let request = ApprovalManager.ApprovalRequest(
                            requestId: "",
                            source: session?.source ?? "unknown",
                            tool: msg.isEmpty ? "AskUserQuestion" : msg,
                            input: session?.lastPrompt ?? "",
                            sessionId: sid,
                            cwdName: session?.cwdName ?? "",
                            terminalName: session?.matchedTerminal?.appName ?? "",
                            timestamp: Date()
                        )
                        approvalManager?.pendingApproval = request
                        approvalManager?.isCardVisible = true
                        showApprovalPanel()
                    }
                }
            }
        }
    }

    // MARK: - 审批面板（叠加式，新卡片错位堆叠）

    /// 每张卡片的错位偏移量
    private static let cardStackOffset: CGFloat = 8

    private func showApprovalPanel() {
        guard let geo = geometry,
              let approval = approvalManager,
              let request = approval.pendingApproval else { return }

        let panelRef = NSPanel.self  // capture for closure
        let cardView = ApprovalCardView(
            request: request,
            onDeny: { [weak self] in
                approval.deny()
                self?.removeTopApprovalPanel()
            },
            onApprove: { [weak self] in
                approval.approve()
                self?.removeTopApprovalPanel()
            },
            onApproveAll: { [weak self] in
                approval.approveAllForSession()
                self?.removeAllApprovalPanels()
            },
            onJump: { [weak self] in
                guard let self,
                      let session = self.sessionManager.sessions[request.sessionId] else { return }
                self.terminalJumper.jumpToSession(session: session)
            },
            onClose: { [weak self] in
                self?.removeTopApprovalPanel()
            }
        )

        let hostingView = NSHostingView(rootView: cardView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let cardWidth: CGFloat = 380
        let cardHeight: CGFloat = 220
        guard let screen = currentScreen ?? NSScreen.main else { return }

        // 每张新卡片向右下偏移
        let stackIndex = CGFloat(approvalPanels.count)
        let cardX = screen.frame.midX + geo.notchSize.width / 2 + 8 + stackIndex * Self.cardStackOffset
        let cardY = screen.frame.maxY - geo.notchSize.height - cardHeight - 4 - stackIndex * Self.cardStackOffset

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
        approvalPanels.append(panel)
    }

    // showQuestionPanel removed — Claude Code doesn't support updatedInput for AskUserQuestion
    // AskUserQuestion 通过 Notification 事件 → 审批卡片（信息 + 跳转按钮）展示

    /// 移除最顶层的审批面板
    private func removeTopApprovalPanel() {
        guard let top = approvalPanels.last else { return }
        top.close()
        approvalPanels.removeLast()
    }

    /// 移除所有审批面板（"全部允许"时）
    private func removeAllApprovalPanels() {
        for panel in approvalPanels {
            panel.close()
        }
        approvalPanels.removeAll()
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
