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
    private var stateBeforeDrag: NotchikkoState?
    private var settingsWindow: NSWindow?
    private var approvalPanel: NSPanel?
    private var hotkeyMonitor: Any?
    private let terminalJumper = TerminalJumper()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        setupMenuBar()
        setupNotchWindow(on: NSScreen.main)
        startAgentListening()
        observeScreenChanges()
        setupGlobalHotkeys()
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
        setupNotchWindow(on: currentScreen)
    }

    private func setupNotchWindow(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        self.currentScreen = screen

        dragController.teardown()
        notchPanel?.orderOut(nil)

        let geo = NotchGeometry(screen: screen)
        self.geometry = geo

        let panel = NotchPanel(frame: geo.panelFrame)
        // 强制设置 frame，防止系统自动调整位置
        panel.setFrame(geo.panelFrame, display: false)

        let petSize = 80 * PreferencesStore.shared.preferences.petScale
        let contentView = NotchContentView(
            notchHeight: geo.notchSize.height,
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
                             notchHeight: geo.notchSize.height, petSize: petSize)
        dragController.onRightClick = { [weak self] screenPoint in
            guard let self, let panel = self.notchPanel else { return }
            self.menuBarManager.buildMenu()
            let localPoint = panel.convertPoint(fromScreen: screenPoint)
            self.menuBarManager.showContextMenu(in: panel, at: localPoint)
        }

        dragController.onClick = { [weak self] in
            guard let self else { return }
            if let sid = self.sessionManager.activeSessionId,
               let session = self.sessionManager.sessions[sid] {
                self.terminalJumper.jumpToSession(cwd: session.cwd)
            }
        }

        dragController.onDragStart = { [weak self] in
            guard let self else { return }
            self.stateBeforeDrag = self.sessionManager.currentState
            self.sessionManager.overrideState(.dragging)
        }
        dragController.onDragEnd = { [weak self] targetScreen in
            guard let self else { return }
            let prevState = self.stateBeforeDrag
            self.stateBeforeDrag = nil

            let landingScreen = targetScreen ?? self.currentScreen ?? NSScreen.main
            guard let landingScreen else { return }
            let isSameScreen = (landingScreen == self.currentScreen)

            if isSameScreen {
                // 同屏：先动画回原位，动画完成后再恢复状态（避免状态切换导致布局跳动）
                guard let geo = self.geometry else { return }
                self.dragController.animateToFrame(geo.panelFrame) {
                    if let prev = prevState {
                        self.sessionManager.overrideState(prev)
                    }
                }
            } else {
                // 跨屏：直接重建到目标屏幕（不做飞行动画，避免闪烁）
                if let prev = prevState {
                    self.sessionManager.overrideState(prev)
                }
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

        // 创建 ApprovalManager 并绑定到 SocketServer
        let approval = ApprovalManager(socketServer: adapter.socketServerRef)
        self.approvalManager = approval

        // 审批请求回调
        adapter.socketServerRef.onApprovalRequest = { [weak self] hookEvent in
            guard let self else { return }
            self.approvalManager?.handleApprovalRequest(from: hookEvent)
            self.sessionManager.overrideState(.approving)
            self.showApprovalPanel()
        }

        Task {
            try? await adapter.start()
            for await event in adapter.eventStream {
                sessionManager.handleEvent(event)
            }
        }
    }

    private func setupGlobalHotkeys() {
        // ⌘Y = approve, ⌘N = deny (仅审批待决时生效)
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let approval = self.approvalManager, approval.hasPendingApproval else {
                return event
            }

            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "y":
                    approval.approve()
                    return nil  // 消费事件
                case "n":
                    approval.deny()
                    return nil
                default:
                    break
                }
            }
            return event
        }
    }

    // MARK: - 独立审批窗口

    private func showApprovalPanel() {
        guard let geo = geometry, let approval = approvalManager else { return }

        // 已有窗口则刷新内容
        if let existing = approvalPanel, existing.isVisible {
            existing.orderFrontRegardless()
            return
        }

        let cardView = ApprovalCardView(
            request: approval.pendingApproval!,
            onApprove: { [weak self] in
                approval.approve()
                self?.hideApprovalPanel()
            },
            onDeny: { [weak self] in
                approval.deny()
                self?.hideApprovalPanel()
            },
            onBypass: { [weak self] in
                // 开启 bypass permissions 并放行当前请求
                Self.enableBypassPermissions()
                approval.approve()
                self?.hideApprovalPanel()
            }
        )

        let hostingView = NSHostingView(rootView: cardView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // 卡片尺寸
        let cardWidth: CGFloat = 260
        let cardHeight: CGFloat = 140
        // 定位到 notch 右侧
        let screen = currentScreen ?? NSScreen.main!
        let cardX = screen.frame.midX + geo.notchSize.width / 2 + 8
        let cardY = screen.frame.maxY - geo.notchSize.height - cardHeight - 4

        let panel = NSPanel(
            contentRect: NSRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar + 1
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false

        let wrapper = NSView(frame: panel.contentView!.bounds)
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
        self.approvalPanel = panel
    }

    private func hideApprovalPanel() {
        approvalPanel?.orderOut(nil)
        approvalPanel = nil
    }

    private static func enableBypassPermissions() {
        let path = NSString(string: "~/.claude/settings.json").expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        json["skipDangerousModePermissionPrompt"] = true
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNotchWindow()
        }

        NotificationCenter.default.addObserver(
            forName: PreferencesStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshNotchWindow()
        }
    }
}
