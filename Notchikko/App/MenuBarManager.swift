import AppKit

final class MenuBarManager {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private weak var sessionManager: SessionManager?
    /// 当前 Notchikko 所在屏幕（由 AppDelegate 更新）
    var currentScreen: NSScreen?

    var onSwitchScreen: ((NSScreen) -> Void)?
    var onQuit: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRemoveSession: ((String) -> Void)?
    var onJumpToSession: ((String) -> Void)?
    /// 会话级自动批准开关：true = 当前已 bypass，点击关闭；反之打开。
    /// 由 AppDelegate 路由到 `ApprovalManager.enableBypass` / `disableBypass`。
    var onToggleAutoApprove: ((String) -> Void)?
    /// 查询某个 session 当前是否处于自动批准态，菜单项用来显示勾选。
    var isSessionAutoApproved: ((String) -> Bool)?
    /// 查询某个 session 是否正在等用户决断（blocking approval / AskUserQuestion）—— 红点用。
    var sessionHasPendingApproval: ((String) -> Bool)?
    /// 查询某个 session 上次工具失败是否尚未复位 —— 红点用。
    var sessionHasError: ((String) -> Bool)?
    /// 隐身态切换：true = 进入隐身，false = 退出。AppDelegate 负责把它映射到 panel 透明度 + ignoresMouseEvents。
    var onToggleStealth: ((Bool) -> Void)?

    /// 运行期状态，不持久化（退出/重启后自动回到普通态）。
    private var isStealthActive: Bool = false

    func setup(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = currentMenubarImage()
        statusItem?.menu = buildMenu()
        observeStateChanges()
    }

    /// 重新读取 SessionManager.currentState → 切换状态栏图标。
    /// 通过 withObservationTracking 重订阅，每次状态变化触发一次。
    private func observeStateChanges() {
        guard let sm = sessionManager else { return }
        withObservationTracking {
            _ = sm.currentState
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusItem?.button?.image = self.currentMenubarImage()
                self.observeStateChanges()
            }
        }
    }

    private func currentMenubarImage() -> NSImage? {
        let name = Self.menubarImageName(for: sessionManager?.currentState ?? .sleeping)
        let image = NSImage(named: name)
        image?.isTemplate = true
        image?.accessibilityDescription = "Notchikko"
        return image
    }

    private static func menubarImageName(for state: NotchikkoState) -> String {
        switch state {
        case .sleeping:
            return "MenubarSleeping"
        case .error, .approving:
            return "MenubarAlert"
        default:
            return "MenubarDefault"
        }
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

                for session in sessions {
                    let isPinned = session.id == sm.pinnedSessionId

                    // 主菜单项（自定义 view）—— 点击主行默认跳转到对应终端
                    let needsAttention = (sessionHasPendingApproval?(session.id) ?? false)
                        || (sessionHasError?(session.id) ?? false)
                    let item = NSMenuItem()
                    let view = SessionMenuItemView(session: session, isPinned: isPinned, needsAttention: needsAttention)
                    item.view = view
                    item.target = self
                    item.action = #selector(jumpToSession(_:))
                    item.representedObject = session.id

                    // 子菜单：固定 / 跳转 / 关闭
                    let sub = NSMenu()
                    let pinTitle = isPinned
                        ? NSLocalizedString("menu.unpin", comment: "")
                        : NSLocalizedString("menu.pin", comment: "")
                    let pinItem = NSMenuItem(title: pinTitle, action: #selector(pinSession(_:)), keyEquivalent: "")
                    pinItem.target = self
                    pinItem.representedObject = session.id
                    sub.addItem(pinItem)

                    let jumpItem = NSMenuItem(title: NSLocalizedString("menu.jump_to_terminal", comment: ""), action: #selector(jumpToSession(_:)), keyEquivalent: "")
                    jumpItem.target = self
                    jumpItem.representedObject = session.id
                    sub.addItem(jumpItem)

                    // 会话级自动批准：把整个 session 切到 bypassPermissions，
                    // 之后该 session 的 PermissionRequest 不再弹卡。再点一次关闭 app 侧
                    // 的自动放行（CLI 侧 bypass 模式无法由外部回退，需要用户在终端 /permissions）。
                    let autoApproved = isSessionAutoApproved?(session.id) ?? false
                    let autoApproveItem = NSMenuItem(
                        title: NSLocalizedString("menu.auto_approve_session", comment: ""),
                        action: #selector(toggleAutoApprove(_:)),
                        keyEquivalent: ""
                    )
                    autoApproveItem.target = self
                    autoApproveItem.representedObject = session.id
                    autoApproveItem.state = autoApproved ? .on : .off
                    sub.addItem(autoApproveItem)

                    sub.addItem(.separator())

                    // Token 用量（单行浓缩）
                    if let usage = session.tokenUsage {
                        let header = NSMenuItem(title: NSLocalizedString("menu.usage", comment: ""), action: nil, keyEquivalent: "")
                        header.isEnabled = false
                        sub.addItem(header)
                        sub.addItem(Self.usageItem("  " + Self.compactUsageLine(usage: usage)))
                        sub.addItem(.separator())
                    }

                    let closeItem = NSMenuItem(title: NSLocalizedString("menu.close_session", comment: ""), action: #selector(closeSession(_:)), keyEquivalent: "")
                    closeItem.target = self
                    closeItem.representedObject = session.id
                    sub.addItem(closeItem)

                    item.submenu = sub
                    menu.addItem(item)
                }

                // Auto 选项放在 session 列表末尾，session 多时更易触达
                let autoItem = NSMenuItem(title: NSLocalizedString("menu.auto", comment: ""), action: #selector(pinSession(_:)), keyEquivalent: "")
                autoItem.target = self
                autoItem.representedObject = nil
                autoItem.state = (sm.pinnedSessionId == nil) ? .on : .off
                menu.addItem(autoItem)

                menu.addItem(.separator())
            }
        }

        // Section 2: 显示器（常驻）——先列连接的屏幕，再列 Notch 检测模式
        let screens = NSScreen.screens
        let screenMenu = NSMenu()
        let currentMode = PreferencesStore.shared.preferences.notchDetectionMode

        if screens.count > 1 {
            for (i, screen) in screens.enumerated() {
                let name = screen.localizedName
                let item = NSMenuItem(title: name, action: #selector(screenSelected(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                if screen == currentScreen {
                    item.state = .on
                }
                screenMenu.addItem(item)
            }
            screenMenu.addItem(.separator())
        }

        // Notch detection section — header + 3 modes
        let notchHeader = NSMenuItem(title: NSLocalizedString("menu.notch_detection", comment: ""),
                                     action: nil, keyEquivalent: "")
        notchHeader.isEnabled = false
        screenMenu.addItem(notchHeader)

        let notchItems: [(NotchDetectionMode, String)] = [
            (.auto, "settings.notch_auto"),
            (.forceOn, "settings.notch_force_on"),
            (.forceOff, "settings.notch_force_off"),
        ]
        for (mode, key) in notchItems {
            let item = NSMenuItem(title: NSLocalizedString(key, comment: ""),
                                  action: #selector(setNotchMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == currentMode) ? .on : .off
            screenMenu.addItem(item)
        }

        let screenItem = NSMenuItem(title: NSLocalizedString("menu.display", comment: ""), action: nil, keyEquivalent: "")
        screenItem.submenu = screenMenu
        menu.addItem(screenItem)

        // 设置（检查更新已移入"更多设置 → 关于"）
        let settingsItem = NSMenuItem(title: NSLocalizedString("menu.settings", comment: ""), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // 隐身开关：透明度 + 屏蔽交互。双行 attributedTitle：主标题 + 副标题描述
        let stealthItem = NSMenuItem(title: "", action: #selector(toggleStealth(_:)), keyEquivalent: "")
        stealthItem.target = self
        stealthItem.attributedTitle = Self.stealthMenuTitle(isActive: isStealthActive)
        menu.addItem(stealthItem)

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

    @objc private func jumpToSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        onJumpToSession?(sessionId)
    }

    @objc private func closeSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        onRemoveSession?(sessionId)
    }

    @objc private func toggleAutoApprove(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? String else { return }
        onToggleAutoApprove?(sessionId)
    }

    @objc private func screenSelected(_ sender: NSMenuItem) {
        let screens = NSScreen.screens
        guard sender.tag < screens.count else { return }
        onSwitchScreen?(screens[sender.tag])
    }

    @objc private func setNotchMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = NotchDetectionMode(rawValue: raw) else { return }
        PreferencesStore.shared.preferences.notchDetectionMode = mode
        // 状态栏菜单不会自动刷新，重建以更新勾选状态
        statusItem?.menu = buildMenu()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        onOpenSettings?()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        onQuit?()
    }

    @objc private func toggleStealth(_ sender: NSMenuItem) {
        isStealthActive.toggle()
        onToggleStealth?(isStealthActive)
        // 重建菜单，让主/副标题切到对应形态
        statusItem?.menu = buildMenu()
    }

    /// 双行菜单项标题：主标题随状态切换；副标题描述功能，较小较淡
    private static func stealthMenuTitle(isActive: Bool) -> NSAttributedString {
        let mainKey = isActive ? "menu.stealth.off" : "menu.stealth.on"
        let main = NSLocalizedString(mainKey, comment: "")
        let subtitle = NSLocalizedString("menu.stealth.subtitle", comment: "")

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: main, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
        ]))
        result.append(NSAttributedString(string: "\n\(subtitle)", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return result
    }

    private static func usageItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 压缩成单行：`12.3K in · 4.5K out · 94K cached`
    private static func compactUsageLine(usage: HookEvent.TokenUsage) -> String {
        var parts: [String] = []
        parts.append("\(formatTokens(usage.inputTokens)) in")
        parts.append("\(formatTokens(usage.outputTokens)) out")
        let cached = usage.cacheRead + usage.cacheCreation
        if cached > 0 {
            parts.append("\(formatTokens(cached)) cached")
        }
        return parts.joined(separator: " · ")
    }

    private static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
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
    /// 红点：该 session 当前正在等用户决断，或上次工具失败未复位。压过 phase 颜色。
    private let needsAttention: Bool

    private static let viewWidth: CGFloat = 300
    private static let viewHeight: CGFloat = 44
    private static let hPadding: CGFloat = 20
    private static let vPadding: CGFloat = 4

    init(session: SessionManager.SessionInfo, isPinned: Bool, needsAttention: Bool) {
        self.session = session
        self.isPinned = isPinned
        self.needsAttention = needsAttention
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))
        setAccessibilityRole(.menuItem)
        let agentName = Self.agentName(for: session.source)
        let terminal = session.matchedTerminal?.appName ?? ""
        let pinMark = isPinned ? "pinned, " : ""
        setAccessibilityLabel("\(pinMark)\(agentName) \(terminal) · \(session.phaseDisplayName)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.viewWidth, height: Self.viewHeight)
    }

    /// NSMenu 对不用 AutoLayout 的 custom view 不一定触发 `layout()`；但 draw 前保证会走 `viewWillDraw`。
    /// 用 `menu.size.width - 36` 作 target：菜单总宽扣掉左右系统 item 边距。
    /// 36 这个固定偏移是不动点 —— 虽然 menu.size 会把自己算进去，但减掉 36 后的值永远小于原 menu.size，
    /// 不会正反馈把菜单撑得越来越宽；`superview.bounds.width` 在 `viewWillDraw` 里等于菜单窗口的全宽（含阴影），不可用。
    override func viewWillDraw() {
        super.viewWillDraw()
        guard let menu = enclosingMenuItem?.menu else { return }
        let target = max(Self.viewWidth, menu.size.width - 36)
        if abs(target - frame.size.width) > 0.5 {
            frame.size.width = target
        }
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
        // 红点压过 phase：有待决断的审批或未复位的工具错误时，统一显示 🔴
        let statusDot = needsAttention ? "🔴" : Self.statusDot(for: session.phase)
        let phaseName = session.phaseDisplayName

        let mainText = "\(pinMark)\(agentIcon) \(agentName)\(terminalSuffix)"
        let mainAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 13),
            .foregroundColor: textColor,
        ]
        let mainStr = NSAttributedString(string: mainText, attributes: mainAttrs)
        mainStr.draw(at: NSPoint(x: x, y: Self.viewHeight - Self.vPadding - 16))

        // 状态点 + phase 靠右
        let rightText = "\(statusDot) \(phaseName)"
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
        // 运行中 = 🟡（processing / 工具执行 / 压缩都属于 agent 在干活）
        case .processing, .runningTool, .compacting: return "🟡"
        // 等待输入 = 🟢
        case .waitingForInput: return "🟢"
        case .ended: return "⚪"
        }
    }
}
