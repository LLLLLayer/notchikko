import Foundation

/// VS Code / Cursor 等 IDE 的终端聚焦扩展安装器
struct IDEExtensionInstaller {

    struct IDETarget: Identifiable {
        let id: String
        let name: String
        let extensionDir: String  // ~/.vscode/extensions, ~/.cursor/extensions, etc.

        var extensionPath: String {
            let dir = NSString(string: extensionDir).expandingTildeInPath
            return "\(dir)/notchikko.notchikko-terminal-focus-1.0.0"
        }

        var isInstalled: Bool {
            FileManager.default.fileExists(atPath: extensionPath)
        }
    }

    static let targets: [IDETarget] = [
        IDETarget(id: "vscode", name: "VS Code", extensionDir: "~/.vscode/extensions"),
    ]

    /// 安装扩展到指定 IDE
    static func install(for target: IDETarget) throws {
        // Xcode 会将 Resources 子目录打平，文件直接在 bundle root
        guard let extJS = Bundle.main.path(forResource: "extension", ofType: "js"),
              let pkgJSON = Bundle.main.path(forResource: "package", ofType: "json")
        else {
            throw InstallerError.sourceNotFound
        }

        let destPath = target.extensionPath
        let fm = FileManager.default

        // 创建目标目录
        try fm.createDirectory(atPath: destPath, withIntermediateDirectories: true)

        // 已存在则先删除再复制
        let destExtJS = "\(destPath)/extension.js"
        let destPkgJSON = "\(destPath)/package.json"
        if fm.fileExists(atPath: destExtJS) { try fm.removeItem(atPath: destExtJS) }
        if fm.fileExists(atPath: destPkgJSON) { try fm.removeItem(atPath: destPkgJSON) }

        try fm.copyItem(atPath: extJS, toPath: destExtJS)
        try fm.copyItem(atPath: pkgJSON, toPath: destPkgJSON)
    }

    /// 卸载扩展
    static func uninstall(for target: IDETarget) throws {
        let path = target.extensionPath
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
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
