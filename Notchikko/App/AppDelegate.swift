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
    private var stateBeforeDrag: NotchikkoState?
    private var petScale: CGFloat = 1.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        setupMenuBar()
        setupNotchWindow(on: NSScreen.main)
        startAgentListening()
        observeScreenChanges()
    }

    private func setupMenuBar() {
        menuBarManager.setup()

        menuBarManager.onResize = { [weak self] scale in
            self?.petScale = scale
            self?.refreshNotchWindow()
        }

        menuBarManager.onSwitchScreen = { [weak self] screen in
            self?.setupNotchWindow(on: screen)
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

        let petSize = 80 * petScale
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
        dragController.setup(panel: panel, homeFrame: geo.panelFrame)
        dragController.onRightClick = { [weak self] screenPoint in
            guard let self, let panel = self.notchPanel else { return }
            self.menuBarManager.buildMenu()
            let localPoint = panel.convertPoint(fromScreen: screenPoint)
            self.menuBarManager.showContextMenu(in: panel, at: localPoint)
        }

        dragController.onDragStart = { [weak self] in
            guard let self else { return }
            self.stateBeforeDrag = self.sessionManager.currentState
            self.sessionManager.overrideState(.dragging)
        }
        dragController.onDragEnd = { [weak self] targetScreen in
            guard let self else { return }
            if let prev = self.stateBeforeDrag {
                self.sessionManager.overrideState(prev)
            }
            self.stateBeforeDrag = nil

            // 计算目标屏幕的归位位置，动画飞过去
            let landingScreen = targetScreen ?? self.currentScreen ?? NSScreen.main
            let targetGeo = NotchGeometry(screen: landingScreen!)
            self.dragController.animateToFrame(targetGeo.panelFrame)

            // 动画结束后，如果换了屏幕则重建窗口
            if landingScreen != self.currentScreen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    self.setupNotchWindow(on: landingScreen)
                }
            }
        }
    }

    private func startAgentListening() {
        let adapter = ClaudeCodeAdapter()
        self.adapter = adapter
        Task {
            try? await adapter.start()
            for await event in adapter.eventStream {
                sessionManager.handleEvent(event)
            }
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
    }
}
