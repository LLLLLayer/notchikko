import AppKit

/// 已知终端应用的 Bundle ID、显示名、跳转策略
enum KnownTerminal: String, CaseIterable {
    case terminal       = "com.apple.Terminal"
    case iterm2         = "com.googlecode.iterm2"
    case ghostty        = "com.mitchellh.ghostty"
    case warp           = "dev.warp.Warp-Stable"
    case kitty          = "net.kovidgoyal.kitty"
    case alacritty      = "org.alacritty"
    case vscode         = "com.microsoft.VSCode"
    case vscodeInsiders = "com.microsoft.VSCodeInsiders"
    case cursor         = "com.todesktop.230313mzl4w4u92"
    case wezterm        = "com.github.wez.wezterm"
    case zed            = "dev.zed.Zed"
    case windsurf       = "com.exafunction.windsurf"
    case hyper          = "co.zeit.hyper"

    var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm2: "iTerm2"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        case .kitty: "Kitty"
        case .alacritty: "Alacritty"
        case .vscode: "VSCode"
        case .vscodeInsiders: "VSCode Insiders"
        case .cursor: "Cursor"
        case .wezterm: "WezTerm"
        case .zed: "Zed"
        case .windsurf: "Windsurf"
        case .hyper: "Hyper"
        }
    }

    /// 跳转策略：每种终端如何精确定位到 session 对应的 tab/pane
    enum FocusStrategy {
        /// AppleScript 按 tty 定位（iTerm2, Terminal.app）
        case appleScriptTty
        /// AppleScript 按 cwd 匹配（Ghostty）
        case appleScriptCwd
        /// HTTP 请求扩展定位终端 tab（VS Code, Cursor, Windsurf）
        case ideExtension
        /// Kitty remote control CLI
        case kittyCLI
        /// 通用：activate app + raise 窗口
        case generic
    }

    var focusStrategy: FocusStrategy {
        switch self {
        case .iterm2, .terminal: .appleScriptTty
        case .ghostty: .appleScriptCwd
        case .vscode, .vscodeInsiders, .cursor, .windsurf: .ideExtension
        case .kitty: .kittyCLI
        default: .generic
        }
    }

    /// 生成 AppleScript 脚本（仅 appleScriptTty/appleScriptCwd 策略使用）
    func appleScript(tty: String?, cwd: String?) -> String? {
        switch self {
        case .iterm2:
            guard let tty else { return nil }
            let safeTty = Self.escapeAppleScript(tty)
            return """
            tell application "iTerm2"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(safeTty)" then
                                select t
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """

        case .terminal:
            guard let tty else { return nil }
            let shortTty = tty.replacingOccurrences(of: "/dev/", with: "")
            let safeShort = Self.escapeAppleScript(shortTty)
            let safeFull = Self.escapeAppleScript("/dev/" + shortTty)
            return """
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(safeShort)" or tty of t is "\(safeFull)" then
                            set selected of t to true
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """

        case .ghostty:
            guard let cwd else { return nil }
            let safeCwd = Self.escapeAppleScript(cwd)
            return """
            tell application "Ghostty"
                activate
                set allSurfaces to {}
                try
                    set allSurfaces to surfaces
                end try
                repeat with s in allSurfaces
                    try
                        set surfaceCwd to working directory of s
                        if surfaceCwd is "\(safeCwd)" then
                            focus s
                            return "matched"
                        end if
                    end try
                end repeat
                return "no-match"
            end tell
            """

        default:
            return nil
        }
    }

    /// 转义 AppleScript 字符串字面量，防止注入
    private static func escapeAppleScript(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .components(separatedBy: .newlines).joined()
    }
}
