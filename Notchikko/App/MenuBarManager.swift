import AppKit

final class MenuBarManager {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    var onResize: ((CGFloat) -> Void)?
    var onSwitchScreen: ((NSScreen) -> Void)?
    var onQuit: (() -> Void)?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "ladybug.fill", accessibilityDescription: "Notchikko")
        }
        statusItem?.menu = buildMenu()
    }

    func buildMenu() -> NSMenu {
        menu.removeAllItems()

        // 大小
        let sizeMenu = NSMenu()
        for (label, scale) in [("小", 0.6), ("中", 1.0), ("大", 1.5)] {
            let item = NSMenuItem(title: label, action: #selector(sizeSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(scale * 100)
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        // 显示器
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
            let screenItem = NSMenuItem(title: "显示器", action: nil, keyEquivalent: "")
            screenItem.submenu = screenMenu
            menu.addItem(screenItem)
        }

        menu.addItem(.separator())

        // 退出
        let quitItem = NSMenuItem(title: "退出 Notchikko", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func sizeSelected(_ sender: NSMenuItem) {
        let scale = CGFloat(sender.tag) / 100.0
        onResize?(scale)
    }

    @objc private func screenSelected(_ sender: NSMenuItem) {
        let screens = NSScreen.screens
        guard sender.tag < screens.count else { return }
        onSwitchScreen?(screens[sender.tag])
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        onQuit?()
    }

    /// 在指定位置弹出右键菜单
    func showContextMenu(in view: NSWindow, at point: NSPoint) {
        menu.popUp(positioning: nil, at: point, in: view.contentView)
    }
}
