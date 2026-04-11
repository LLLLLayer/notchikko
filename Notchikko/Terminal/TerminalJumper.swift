import AppKit
import ApplicationServices

/// 根据 session cwd 查找并激活对应终端窗口
final class TerminalJumper {

    private static let terminalBundleIds = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
    ]

    /// 跳转到 session 对应的终端窗口
    func jumpToSession(cwd: String) {
        guard !cwd.isEmpty else { return }

        // 检查 Accessibility 权限
        guard AXIsProcessTrusted() else {
            promptAccessibility()
            return
        }

        let cwdName = (cwd as NSString).lastPathComponent

        // 遍历运行中的终端，匹配窗口标题
        let runningTerminals = NSWorkspace.shared.runningApplications
            .filter { Self.terminalBundleIds.contains($0.bundleIdentifier ?? "") }

        for app in runningTerminals {
            let appRef = AXUIElementCreateApplication(app.processIdentifier)
            if let window = findWindowMatching(cwd: cwd, cwdName: cwdName, in: appRef) {
                app.activate()
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return
            }
        }

        // 没找到匹配窗口 — 打开默认终端
        openNewTerminal(at: cwd)
    }

    // MARK: - Private

    private func findWindowMatching(cwd: String, cwdName: String, in app: AXUIElement) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String else {
                continue
            }

            // 匹配: 窗口标题包含完整路径或目录名
            if title.contains(cwd) || title.contains(cwdName) {
                return window
            }
        }

        return nil
    }

    private func openNewTerminal(at path: String) {
        let escapedPath = path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "cd \\"\(escapedPath)\\""
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    private func promptAccessibility() {
        // 触发系统 Accessibility 权限弹窗
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
