import Foundation

/// 主题包描述文件 (theme.json)
struct ThemeManifest: Codable {
    let name: String              // 显示名称
    let author: String?
    let version: String?

    /// 状态 → SVG 文件名映射（不含扩展名）
    /// 未列出的状态使用默认文件名 (state rawValue)
    let animations: [String: String]?

    /// 音效映射：状态名 → 音频文件名（在主题目录 sounds/ 下）
    let sounds: [String: String]?

    /// 眼球追踪配置
    let eyeTracking: EyeTrackingConfig?

    /// 反应动画：点击/拖拽等交互时播放的 SVG
    let reactions: ReactionConfig?

    /// SVG 画布配置
    let viewBox: ViewBoxConfig?

    /// 多 session 工作层级（根据并发 session 数切换不同动画）
    let workingTiers: [WorkingTier]?

    // MARK: - 子结构

    struct EyeTrackingConfig: Codable {
        let enabled: Bool
        let elementIds: EyeTrackingElements?
        let maxOffset: Double?       // 默认 3.0
        let bodyLeanScale: Double?   // 默认 0.3

        struct EyeTrackingElements: Codable {
            let eyes: String?        // 默认 "eyes-js"
            let body: String?        // 默认 "body-js"
        }
    }

    struct ReactionConfig: Codable {
        let click: String?           // 点击时的 SVG 文件名
        let doubleClick: String?     // 双击
        let drag: String?            // 拖拽中
        let duration: Double?        // 反应动画持续时间（秒），默认 1.0
    }

    struct ViewBoxConfig: Codable {
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
    }

    struct WorkingTier: Codable {
        let minSessions: Int         // 最少并发 session 数
        let animation: String        // 对应的 SVG 文件名
    }
}

/// 主题管理器 — 管理内置和自定义主题
@MainActor
final class ThemeProvider {
    static let shared = ThemeProvider()

    /// 内置主题 ID
    static let builtinThemeId = "clawd"

    /// 当前主题 ID
    var currentThemeId: String {
        get { PreferencesStore.shared.preferences.themeId }
        set { PreferencesStore.shared.preferences.themeId = newValue }
    }

    /// 所有可用主题
    var availableThemes: [ThemeInfo] {
        var themes: [ThemeInfo] = []

        // 内置主题
        themes.append(ThemeInfo(
            id: Self.builtinThemeId,
            name: "Clawd",
            author: "Notchikko",
            isBuiltin: true
        ))

        // 扫描自定义主题目录
        let customDir = Self.customThemesDir
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: customDir, includingPropertiesForKeys: nil
        ) {
            for dir in contents where dir.hasDirectoryPath {
                let themeId = dir.lastPathComponent
                let manifestURL = dir.appendingPathComponent("theme.json")
                if let data = try? Data(contentsOf: manifestURL),
                   let manifest = try? JSONDecoder().decode(ThemeManifest.self, from: data) {
                    themes.append(ThemeInfo(
                        id: themeId,
                        name: manifest.name,
                        author: manifest.author,
                        isBuiltin: false
                    ))
                }
            }
        }

        return themes
    }

    /// 获取指定状态的 SVG 文件 URL（同一状态有多个 SVG 时随机选一个）
    func svgURL(for state: NotchikkoState) -> URL? {
        if currentThemeId == Self.builtinThemeId {
            return builtinSVG(for: state)
        }

        // 自定义主题
        let themeDir = Self.customThemesDir.appendingPathComponent(currentThemeId)
        let dirName = customDirName(for: state)

        // 1. 目录模式：扫描子目录内所有 SVG 随机选取
        if let url = randomSVG(in: themeDir.appendingPathComponent(dirName)) {
            return url
        }

        // 2. 单文件模式（向后兼容）
        let flatURL = themeDir.appendingPathComponent("\(dirName).svg")
        if FileManager.default.fileExists(atPath: flatURL.path) {
            return flatURL
        }

        // 3. 回退到内置主题
        return builtinSVG(for: state)
    }

    /// 内置主题：Bundle 内 SVG 按 "{state}-" 前缀命名，随机选取
    /// 源文件结构: themes/clawd/{state}/{state}-xxx.svg
    /// Xcode 打包后展平为: {state}-xxx.svg（文件名全局唯一）
    private func builtinSVG(for state: NotchikkoState) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let prefix = "\(state.rawValue)-"
        guard let all = try? FileManager.default.contentsOfDirectory(
            at: resourceURL, includingPropertiesForKeys: nil
        ) else { return nil }
        let candidates = all.filter {
            $0.pathExtension.lowercased() == "svg" && $0.lastPathComponent.hasPrefix(prefix)
        }
        return candidates.randomElement()
    }

    /// 自定义主题的目录/文件名（manifest 映射优先，否则用 state 名）
    private func customDirName(for state: NotchikkoState) -> String {
        if let mapping = loadManifest(for: currentThemeId)?.animations,
           let custom = mapping[state.rawValue] {
            return custom
        }
        return state.rawValue
    }

    /// 扫描目录内所有 .svg 文件，随机返回一个
    private func randomSVG(in dir: URL) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension.lowercased() == "svg" }),
              let picked = contents.randomElement() else {
            return nil
        }
        return picked
    }

    private func loadManifest(for themeId: String) -> ThemeManifest? {
        let url = Self.customThemesDir
            .appendingPathComponent(themeId)
            .appendingPathComponent("theme.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ThemeManifest.self, from: data)
    }

    // MARK: - 主题导入

    /// 导入主题包（文件夹，需包含 theme.json + SVG 文件）
    func importTheme(from sourceDir: URL) throws -> String {
        let manifestURL = sourceDir.appendingPathComponent("theme.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ThemeError.missingManifest
        }

        let data = try Data(contentsOf: manifestURL)
        _ = try JSONDecoder().decode(ThemeManifest.self, from: data)

        let themeId = sourceDir.lastPathComponent
        let destDir = Self.customThemesDir.appendingPathComponent(themeId)

        if FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.removeItem(at: destDir)
        }

        try FileManager.default.createDirectory(
            at: Self.customThemesDir, withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceDir, to: destDir)

        return themeId
    }

    /// 删除自定义主题
    func removeTheme(_ themeId: String) throws {
        guard themeId != Self.builtinThemeId else { return }
        let dir = Self.customThemesDir.appendingPathComponent(themeId)
        try FileManager.default.removeItem(at: dir)

        // 如果删的是当前主题，切回内置
        if currentThemeId == themeId {
            currentThemeId = Self.builtinThemeId
        }
    }

    // MARK: - Paths

    static var customThemesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchikko/themes")
    }

    enum ThemeError: Error {
        case missingManifest
    }
}

/// 主题信息（供 UI 展示）
struct ThemeInfo: Identifiable {
    let id: String
    let name: String
    let author: String?
    let isBuiltin: Bool
}
