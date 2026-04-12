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
    private var approvalPanel: NSPanel?
    private var hotkeyMonitor: Any?
    private let terminalJumper = TerminalJumper()

    private var screenObserver: NSObjectProtocol?
    private var prefsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        setupMenuBar()
        setupNotchWindow(on: NSScreen.main)
        startAgentListening()
        observeScreenChanges()
        setupGlobalHotkeys()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyMonitor = nil
        }
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

        // 创建 ApprovalManager 并绑定到 SocketServer
        let approval = ApprovalManager(socketServer: adapter.socketServerRef)
        self.approvalManager = approval

        // 审批请求回调
        adapter.socketServerRef.onApprovalRequest = { [weak self] hookEvent in
            guard let self else { return }
            self.approvalManager?.handleApprovalRequest(from: hookEvent)

            // Auto 模式下，自动切到需要审批的 session
            if self.sessionManager.pinnedSessionId == nil {
                let approvalSid = hookEvent.sessionId
                if approvalSid != self.sessionManager.activeSessionId {
                    self.sessionManager.pinSession(approvalSid)
                }
            }

            self.sessionManager.overrideState(.approving)
            self.showApprovalPanel()
        }

        // 终端 PID/tty 更新回调（每个 hook 事件都可能携带）
        adapter.onTerminalPidUpdate = { [weak self] sessionId, pid in
            self?.sessionManager.setTerminalPid(pid, for: sessionId)
        }
        adapter.onTerminalTtyUpdate = { [weak self] sessionId, tty in
            self?.sessionManager.setTerminalTty(tty, for: sessionId)
        }

        Task {
            try? await adapter.start()
            for await event in adapter.eventStream {
                sessionManager.handleEvent(event)
                // 收到后续事件时，如果审批卡片还在显示且属于同一 session，自动清理
                if let approval = self.approvalManager, approval.hasPendingApproval {
                    let sid: String
                    switch event {
                    case .toolUse(let s, _, let phase):
                        if case .post = phase { sid = s } else { continue }
                    case .prompt(let s, _): sid = s
                    case .stop(let s): sid = s
                    case .error(let s, _): sid = s
                    default: continue
                    }
                    approval.onSessionEvent(sessionId: sid)
                    self.hideApprovalPanel()
                }
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
        guard let geo = geometry,
              let approval = approvalManager,
              let request = approval.pendingApproval else { return }

        // 已有窗口则刷新内容
        if let existing = approvalPanel, existing.isVisible {
            existing.orderFrontRegardless()
            return
        }

        let cardView = ApprovalCardView(
            request: request,
            onDeny: { [weak self] in
                approval.deny()
                self?.hideApprovalPanel()
            },
            onApprove: { [weak self] in
                approval.approve()
                self?.hideApprovalPanel()
            },
            onApproveAll: { [weak self] in
                approval.approveAllForSession()
                self?.hideApprovalPanel()
            },
            onJump: { [weak self] in
                guard let self,
                      let session = self.sessionManager.sessions[request.sessionId] else { return }
                self.terminalJumper.jumpToSession(session: session)
            }
        )

        let hostingView = NSHostingView(rootView: cardView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // 卡片尺寸
        let cardWidth: CGFloat = 380
        let cardHeight: CGFloat = 220
        // 定位到 notch 右侧
        guard let screen = currentScreen ?? NSScreen.main else { return }
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
        panel.isReleasedWhenClosed = false

        let contentBounds = panel.contentView?.bounds ?? panel.frame
        let wrapper = NSView(frame: contentBounds)
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
