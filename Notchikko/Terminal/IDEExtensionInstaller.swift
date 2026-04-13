import Foundation

/// VS Code 等 IDE 的终端聚焦扩展安装器
struct IDEExtensionInstaller {

    struct IDETarget: Identifiable {
        let id: String
        let name: String
        let extensionDir: String  // ~/.vscode/extensions, etc.

        var extensionPath: String {
            let dir = NSString(string: extensionDir).expandingTildeInPath
            return "\(dir)/notchikko.notchikko-terminal-focus"
        }

        /// 旧版带版本号的路径（用于迁移清理）
        private var legacyExtensionPath: String {
            let dir = NSString(string: extensionDir).expandingTildeInPath
            return "\(dir)/notchikko.notchikko-terminal-focus-1.0.0"
        }

        var isInstalled: Bool {
            let fm = FileManager.default
            return fm.fileExists(atPath: "\(extensionPath)/package.json")
                || fm.fileExists(atPath: "\(legacyExtensionPath)/package.json")
        }

        /// 读取已安装版本
        var installedVersion: String? {
            for path in [extensionPath, legacyExtensionPath] {
                let pkgPath = "\(path)/package.json"
                guard let data = FileManager.default.contents(atPath: pkgPath),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = json["version"] as? String
                else { continue }
                return version
            }
            return nil
        }

        /// 清理旧版目录
        func cleanupLegacy() {
            let fm = FileManager.default
            if fm.fileExists(atPath: legacyExtensionPath) {
                try? fm.removeItem(atPath: legacyExtensionPath)
            }
        }
    }

    static let targets: [IDETarget] = [
        IDETarget(id: "vscode", name: "VS Code", extensionDir: "~/.vscode/extensions"),
    ]

    // MARK: - 安装/卸载

    static func install(for target: IDETarget) throws {
        guard let extJS = Bundle.main.path(forResource: "vscode-ext", ofType: "js"),
              let pkgJSON = Bundle.main.path(forResource: "vscode-ext-package", ofType: "json")
        else {
            throw InstallerError.sourceNotFound
        }

        let destPath = target.extensionPath
        let fm = FileManager.default

        // 清理旧版
        target.cleanupLegacy()

        // 创建目标目录
        try fm.createDirectory(atPath: destPath, withIntermediateDirectories: true)

        let destExtJS = "\(destPath)/extension.js"
        let destPkgJSON = "\(destPath)/package.json"
        if fm.fileExists(atPath: destExtJS) { try fm.removeItem(atPath: destExtJS) }
        if fm.fileExists(atPath: destPkgJSON) { try fm.removeItem(atPath: destPkgJSON) }

        try fm.copyItem(atPath: extJS, toPath: destExtJS)
        try fm.copyItem(atPath: pkgJSON, toPath: destPkgJSON)
    }

    static func uninstall(for target: IDETarget) throws {
        let fm = FileManager.default
        let path = target.extensionPath
        if fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }
        target.cleanupLegacy()
    }

    // MARK: - 状态检测

    enum ExtensionStatus: Equatable {
        case notInstalled
        case installed              // 已安装，未运行（或无法探测）
        case running(version: String)
        case updateAvailable
    }

    /// 读取 bundle 内的扩展版本号
    static var bundledVersion: String {
        guard let path = Bundle.main.path(forResource: "vscode-ext-package", ofType: "json"),
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String
        else { return "1.0.0" }
        return version
    }

    /// 探测扩展状态：未安装 / 已安装 / 运行中 / 需更新
    static func checkStatus(for target: IDETarget) async -> ExtensionStatus {
        guard target.isInstalled else { return .notInstalled }

        // 先检查文件版本是否过期
        if let installed = target.installedVersion, installed != bundledVersion {
            return .updateAvailable
        }

        // 探测 HTTP 端口看是否在运行
        let portBase = 23456
        let portRange = 5
        for port in portBase..<(portBase + portRange) {
            guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 0.5

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let version = json["version"] as? String
                else { continue }

                if version != bundledVersion {
                    return .updateAvailable
                }
                return .running(version: version)
            } catch {
                continue
            }
        }
        return .installed
    }

    enum InstallerError: LocalizedError {
        case sourceNotFound

        var errorDescription: String? {
            switch self {
            case .sourceNotFound: return "Extension source files not found in bundle"
            }
        }
    }
}
