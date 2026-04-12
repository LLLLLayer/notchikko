import AppKit

final class MenuBarManager {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private weak var sessionManager: SessionManager?

    var onSwitchScreen: ((NSScreen) -> Void)?
    var onQuit: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    func setup(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "ladybug.fill", accessibilityDescription: "Notchikko")
        }
        statusItem?.menu = buildMenu()
    }

    @discardableResult
    func buildMenu() -> NSMenu {
        menu.removeAllItems()

        // Section 1: Sessions
        if let sm = sessionManager {
            let sessions = sm.activeSessions
            if !sessions.isEmpty {
                let header = NSMenuItem(title: NSLocalizedString("menu.sessions", comment: ""), action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)

                // Auto 选项（自动跟踪最新活跃 session）
                let autoItem = NSMenuItem(title: NSLocalizedString("menu.auto", comment: ""), action: #selector(pinSession(_:)), keyEquivalent: "")
                autoItem.target = self
                autoItem.representedObject = nil
                autoItem.state = (sm.pinnedSessionId == nil) ? .on : .off
                menu.addItem(autoItem)

                for session in sessions {
                    let icon = agentIcon(for: session.source)
                    let title = "\(icon) #\(session.id.prefix(6)) — \(session.phaseDisplayName)  \(session.cwdName)"
                    let item = NSMenuItem(title: title, action: #selector(pinSession(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = session.id
                    item.state = (session.id == sm.pinnedSessionId) ? .on : .off
                    menu.addItem(item)
                }

                menu.addItem(.separator())
            }
        }

        // Section 2: 显示器
        let screens = NSScreen.screens
        if screens.count > 1 {
            let screenMenu = NSMenu()
            for (i, screen) in screens.enumerated() {
                let name = screen.localizedName
                let item = NSMenuItem(title: "\(name)", action: #selector(screenSelected(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                if screen == NSScreen.main {
                    item.state = .on
                }
                screenMenu.addItem(item)
            }
            let screenItem = NSMenuItem(title: NSLocalizedString("menu.display", comment: ""), action: nil, keyEquivalent: "")
            screenItem.submenu = screenMenu
            menu.addItem(screenItem)
        }

        // 设置
        let settingsItem = NSMenuItem(title: NSLocalizedString("menu.settings", comment: ""), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // 退出
        let quitItem = NSMenuItem(title: NSLocalizedString("menu.quit", comment: ""), action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.addItem(.separator())

        // 版本号
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2"
        let versionItem = NSMenuItem(title: "Notchikko v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        return menu
    }

    // MARK: - Actions

    @objc private func pinSession(_ sender: NSMenuItem) {
        guard let sm = sessionManager else { return }
        if let sessionId = sender.representedObject as? String {
            // 点击具体 session → 绑定（再次点击同一个 → 取消）
            if sm.pinnedSessionId == sessionId {
                sm.pinSession(nil)
            } else {
                sm.pinSession(sessionId)
            }
        } else {
            // 点击 Auto → 取消绑定，回到自动模式
            sm.pinSession(nil)
        }
    }

    @objc private func screenSelected(_ sender: NSMenuItem) {
        let screens = NSScreen.screens
        guard sender.tag < screens.count else { return }
        onSwitchScreen?(screens[sender.tag])
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        onOpenSettings?()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        onQuit?()
    }

    // MARK: - Helpers

    private func agentIcon(for source: String) -> String {
        switch source {
        case "claude-code": return "🤖"
        case "codex": return "📦"
        default: return "🔧"
        }
    }

    /// 在指定位置弹出右键菜单
    func showContextMenu(in view: NSWindow, at point: NSPoint) {
        buildMenu()
        menu.popUp(positioning: nil, at: point, in: view.contentView)
    }
}
