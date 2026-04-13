import AppKit
import ApplicationServices

/// 根据 session 信息查找并激活对应终端窗口
final class TerminalJumper {

    // MARK: - 进程树缓存（单次 ps 批量获取）
    private var processTree: [Int: Int] = [:]  // pid → ppid
    private var processTreeTimestamp: Date = .distantPast

    /// 跳转到 session 对应的终端
    /// 优先级：terminalPid 直接激活 → cwd 标题匹配 → CGWindowList 跨桌面
    func jumpToSession(session: SessionManager.SessionInfo) {
        guard AXIsProcessTrusted() else {
            promptAccessibility()
            return
        }

        let normalizedCwd = Self.normalizePath(session.cwd)

        // 方案 1：有 terminalPid → 用 PID 或其祖先找到 GUI app 并激活
        if let pid = session.terminalPid,
           let app = findGUIApp(from: pid) {
            #if DEBUG
            print("[TerminalJumper] PID match: pid=\(pid) → \(app.localizedName ?? "?") (pid=\(app.processIdentifier))")
            #endif
            focusApp(app, session: session, normalizedCwd: normalizedCwd)
            return
        }

        // 方案 2：无 PID → 按 cwd 多层目录匹配
        let candidates = Self.cwdCandidates(from: normalizedCwd)
        let runningApps = NSWorkspace.shared.runningApplications

        for terminal in KnownTerminal.allCases {
            guard let app = runningApps.first(where: {
                $0.bundleIdentifier == terminal.rawValue
            }) else { continue }

            // AX：当前 Space
            if matchAndFocusWindow(app: app, candidates: candidates, fullPath: normalizedCwd) {
                return
            }

            // CGWindowList：跨 Space
            if matchAcrossSpaces(candidates: candidates, fullPath: normalizedCwd, pid: app.processIdentifier) {
                app.activate(options: .activateIgnoringOtherApps)
                #if DEBUG
                print("[TerminalJumper] CGWindowList match: \(terminal.displayName)")
                #endif
                return
            }
        }

        #if DEBUG
        print("[TerminalJumper] no match for cwd=\(session.cwdName)")
        #endif
    }

    // MARK: - Focus Dispatch

    /// 根据终端的 focusStrategy 选择跳转方式
    private func focusApp(_ app: NSRunningApplication, session: SessionManager.SessionInfo, normalizedCwd: String) {
        let terminal = KnownTerminal(rawValue: app.bundleIdentifier ?? "")

        if let terminal {
            switch terminal.focusStrategy {
            case .appleScriptTty:
                if let script = terminal.appleScript(tty: session.terminalTty, cwd: nil) {
                    runAppleScript(script, label: "\(terminal.displayName) tty=\(session.terminalTty ?? "?")")
                    return
                }
            case .appleScriptCwd:
                if let script = terminal.appleScript(tty: nil, cwd: normalizedCwd) {
                    let result = runAppleScript(script, label: "\(terminal.displayName) cwd")
                    if result?.contains("matched") == true { return }
                }
            case .ideExtension:
                if let pids = session.pidChain, !pids.isEmpty {
                    focusIDETerminalTab(pids: pids, app: app, label: terminal.displayName)
                    return
                }
                // 无 PID 链则 fallthrough 到通用激活
            case .generic:
                break  // fall through to generic activation
            }
        }

        // 通用 fallback：activate + raise 第一个窗口
        app.activate(options: .activateIgnoringOtherApps)
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        if let windows = axWindows(of: appRef), let first = windows.first {
            AXUIElementPerformAction(first, kAXRaiseAction as CFString)
        }
    }

    // MARK: - IDE Extension (HTTP)

    /// 通过 HTTP 请求 VS Code 扩展定位终端 tab
    /// 扩展 terminal.show(false) 会自动把正确的窗口带到前台
    /// 如果所有端口都没匹配到，fallback 到通用窗口激活
    private func focusIDETerminalTab(pids: [Int], app: NSRunningApplication, label: String) {
        let portBase = 23456
        let portRange = 5
        let body: [String: Any] = ["pids": pids]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            app.activate(options: .activateIgnoringOtherApps)
            return
        }

        Task.detached {
            // 广播到所有端口（每个 VS Code 窗口占一个端口），命中的窗口会自动聚焦
            for port in portBase..<(portBase + portRange) {
                guard let url = URL(string: "http://127.0.0.1:\(port)/focus-tab") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = bodyData
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 1

                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                        #if DEBUG
                        print("[TerminalJumper] IDE extension focused terminal on port \(port) for \(label)")
                        #endif
                        return
                    }
                } catch {
                    continue
                }
            }
            // 所有端口都没匹配到（扩展未安装或终端不匹配）→ fallback 通用激活
            await MainActor.run {
                app.activate(options: .activateIgnoringOtherApps)
            }
            #if DEBUG
            print("[TerminalJumper] IDE extension fallback: generic activate for \(label)")
            #endif
        }
    }

    // MARK: - Window Matching

    /// AX 当前 Space 窗口标题匹配
    private func matchAndFocusWindow(app: NSRunningApplication, candidates: [String], fullPath: String) -> Bool {
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = axWindows(of: appRef) else { return false }

        for window in windows {
            guard let title = axTitle(of: window) else { continue }
            if Self.titleMatchesCwd(title, candidates: candidates, fullPath: fullPath) {
                app.activate(options: .activateIgnoringOtherApps)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                #if DEBUG
                print("[TerminalJumper] AX title match: \(app.localizedName ?? "?") \"\(title)\"")
                #endif
                return true
            }
        }
        return false
    }

    /// CGWindowList 跨 Space 搜索
    private func matchAcrossSpaces(candidates: [String], fullPath: String, pid: pid_t) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let targetPid = Int(pid)
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == targetPid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { continue }

            let title = info[kCGWindowName as String] as? String ?? ""
            if Self.titleMatchesCwd(title, candidates: candidates, fullPath: fullPath) {
                return true
            }
        }
        return false
    }

    // MARK: - Process Tree (Batch)

    /// 从指定 PID 开始，向上查找属于 GUI app 的进程
    /// 使用缓存的进程树（5 秒有效期），避免每层 spawn 一个 Process
    private func findGUIApp(from pid: Int) -> NSRunningApplication? {
        refreshProcessTreeIfNeeded()
        let apps = NSWorkspace.shared.runningApplications
        var currentPid = pid

        for _ in 0..<15 {
            if currentPid <= 1 { break }
            if let app = apps.first(where: { $0.processIdentifier == pid_t(currentPid) }) {
                return app
            }
            guard let ppid = processTree[currentPid] else { break }
            currentPid = ppid
        }
        return nil
    }

    /// 单次 ps 批量获取全部进程树（缓存 5 秒）
    private func refreshProcessTreeIfNeeded() {
        guard Date().timeIntervalSince(processTreeTimestamp) > 5 else { return }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid=,ppid="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return }

            var tree: [Int: Int] = [:]
            for line in output.split(separator: "\n") {
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2, let pid = Int(parts[0]), let ppid = Int(parts[1]) {
                    tree[pid] = ppid
                }
            }
            processTree = tree
            processTreeTimestamp = Date()
        } catch {}
    }

    // MARK: - CWD Matching (static)

    /// 从 cwd 提取最多 3 层目录候选（最深优先 = 最具体优先）
    static func cwdCandidates(from cwd: String) -> [String] {
        var candidates: [String] = []
        var dir = cwd
        for _ in 0..<3 {
            let name = (dir as NSString).lastPathComponent
            if name.isEmpty || name == "/" || name == dir { break }
            candidates.append(name)
            dir = (dir as NSString).deletingLastPathComponent
        }
        return candidates
    }

    /// 标题是否匹配 cwd（完整路径或任一候选目录名）
    static func titleMatchesCwd(_ title: String, candidates: [String], fullPath: String) -> Bool {
        if title.contains(fullPath) { return true }
        for candidate in candidates {
            if title.contains(candidate) { return true }
        }
        return false
    }

    /// 路径归一化：解析 symlink + 标准化
    static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Helpers

    @discardableResult
    private func runAppleScript(_ source: String, label: String) -> String? {
        #if DEBUG
        print("[TerminalJumper] AppleScript: \(label)")
        #endif
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        #if DEBUG
        if let error { print("[TerminalJumper] AppleScript error: \(error)") }
        #endif
        return result.stringValue
    }

    private func axWindows(of app: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? [AXUIElement]
    }

    private func axTitle(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
