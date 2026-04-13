import AppKit

final class MenuBarManager {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private weak var sessionManager: SessionManager?
    /// 当前宠物所在屏幕（由 AppDelegate 更新）
    var currentScreen: NSScreen?

    var onSwitchScreen: ((NSScreen) -> Void)?
    var onQuit: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRemoveSession: ((String) -> Void)?

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

                // Auto 选项
                let autoItem = NSMenuItem(title: NSLocalizedString("menu.auto", comment: ""), action: #selector(pinSession(_:)), keyEquivalent: "")
                autoItem.target = self
                autoItem.representedObject = nil
                autoItem.state = (sm.pinnedSessionId == nil) ? .on : .off
                menu.addItem(autoItem)

                for session in sessions {
                    let isPinned = session.id == sm.pinnedSessionId

                    // 主菜单项（自定义 view）
                    let item = NSMenuItem()
                    let view = SessionMenuItemView(session: session, isPinned: isPinned)
                    item.view = view

                    // 子菜单：Pin/Unpin + Close
                    let sub = NSMenu()
                    let pinTitle = isPinned
                        ? NSLocalizedString("menu.unpin", comment: "")
                        : NSLocalizedString("menu.pin", comment: "")
                    let pinItem = NSMenuItem(title: pinTitle, action: #selector(pinSession(_:)), keyEquivalent: "")
                    pinItem.target = self
                    pinItem.representedObject = session.id
                    sub.addItem(pinItem)

                    let closeItem = NSMenuItem(title: NSLocalizedString("menu.close_session", comment: ""), action: #selector(closeSession(_:)), keyEquivalent: "")
                    closeItem.target = self
                    closeItem.representedObject = session.id
                    sub.addItem(closeItem)

                    item.submenu = sub
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
                if screen == currentScreen {
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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3"
        let versionItem = NSMenuItem(title: "Notchikko v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        return menu
    }

    // MARK: - Actions

    @objc private func pinSession(_ sender: NSMenuItem) {
        guard let sm = sessionManager else { return }
        if let sessionId = sender.representedObject as? String {
            if sm.pinnedSessionId == sessionId {
                sm.pinSession(nil)
            } else {
                sm.pinSession(sessionId)
            }
        } else {
            sm.pinSession(nil)
        }
    }

    @objc private func closeSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        onRemoveSession?(sessionId)
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

    /// 在指定位置弹出右键菜单
    func showContextMenu(in view: NSWindow, at point: NSPoint) {
        buildMenu()
        menu.popUp(positioning: nil, at: point, in: view.contentView)
    }
}

// MARK: - 自定义双行菜单项视图

private final class SessionMenuItemView: NSView {
    private let session: SessionManager.SessionInfo
    private let isPinned: Bool

    private static let viewWidth: CGFloat = 300
    private static let viewHeight: CGFloat = 44
    private static let hPadding: CGFloat = 20
    private static let vPadding: CGFloat = 4

    init(session: SessionManager.SessionInfo, isPinned: Bool) {
        self.session = session
        self.isPinned = isPinned
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.viewWidth, height: Self.viewHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let isHighlighted = enclosingMenuItem?.isHighlighted ?? false

        // 高亮背景
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4)
            path.fill()
        }

        let textColor = isHighlighted ? NSColor.white : NSColor.labelColor
        let subtitleColor = isHighlighted ? NSColor.white.withAlphaComponent(0.7) : NSColor.secondaryLabelColor

        let x = Self.hPadding

        // 主行：pin 指示 + agent icon + agent 名称 + 终端 + 状态点 + phase
        let pinMark = isPinned ? "✓ " : "   "
        let agentIcon = Self.agentIcon(for: session.source)
        let agentName = Self.agentName(for: session.source)
        let terminalName = session.matchedTerminal?.appName ?? ""
        let terminalSuffix = terminalName.isEmpty ? "" : " · \(terminalName)"
        let statusDot = Self.statusDot(for: session.phase)
        let phaseName = session.phaseDisplayName

        let mainText = "\(pinMark)\(agentIcon) \(agentName)\(terminalSuffix)"
        let mainAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: textColor,
        ]
        let mainStr = NSAttributedString(string: mainText, attributes: mainAttrs)
        mainStr.draw(at: NSPoint(x: x, y: Self.viewHeight - Self.vPadding - 16))

        // 状态点 + phase + token 用量靠右
        let tokenSuffix: String = {
            guard let usage = session.tokenUsage else { return "" }
            let total = usage.totalTokens
            if total >= 1_000_000 {
                return String(format: "  %.1fM tk · $%.2f", Double(total) / 1_000_000, usage.estimatedCostUSD)
            } else if total >= 1_000 {
                return String(format: "  %.0fK tk · $%.2f", Double(total) / 1_000, usage.estimatedCostUSD)
            }
            return ""
        }()
        let rightText = "\(statusDot) \(phaseName)\(tokenSuffix)"
        let rightAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 12),
            .foregroundColor: subtitleColor,
        ]
        let rightStr = NSAttributedString(string: rightText, attributes: rightAttrs)
        let rightWidth = rightStr.size().width
        rightStr.draw(at: NSPoint(x: bounds.width - rightWidth - Self.hPadding, y: Self.viewHeight - Self.vPadding - 15))

        // 副行：subtitle（prompt / tool summary / cwd），限制宽度避免溢出
        let subtitleText = session.subtitle
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 11),
            .foregroundColor: subtitleColor,
            .obliqueness: NSNumber(value: 0.1),
            .paragraphStyle: {
                let ps = NSMutableParagraphStyle()
                ps.lineBreakMode = .byTruncatingTail
                return ps
            }(),
        ]
        let subtitleStr = NSAttributedString(string: subtitleText, attributes: subtitleAttrs)
        let subtitleX = x + 20
        let subtitleRect = NSRect(x: subtitleX, y: Self.vPadding,
                                  width: bounds.width - subtitleX - Self.hPadding,
                                  height: 16)
        subtitleStr.draw(in: subtitleRect)
    }

    override func mouseUp(with event: NSEvent) {
        guard let menuItem = enclosingMenuItem, let menu = menuItem.menu else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: menu.index(of: menuItem))
    }

    // MARK: - Helpers

    private static func agentIcon(for source: String) -> String {
        CLIHookConfig.metadata(for: source).icon
    }

    private static func agentName(for source: String) -> String {
        CLIHookConfig.metadata(for: source).displayName
    }

    private static func statusDot(for phase: SessionManager.SessionPhase) -> String {
        switch phase {
        case .processing, .runningTool: return "🟢"
        case .waitingForInput: return "🟡"
        case .compacting: return "🟠"
        case .ended: return "⚪"
        }
    }
}
