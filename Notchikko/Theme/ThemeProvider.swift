import Foundation

/// 主题包描述文件 (theme.json)
struct ThemeManifest: Codable {
    let name: String              // 显示名称
    let author: String?
    let version: String?
    /// 状态 → SVG 文件名映射（不含扩展名）
    /// 未列出的状态使用默认文件名 (state rawValue)
    let animations: [String: String]?
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

    /// 获取指定状态的 SVG 文件 URL
    func svgURL(for state: NotchikkoState) -> URL? {
        let fileName = svgFileName(for: state)

        if currentThemeId == Self.builtinThemeId {
            // 内置主题：从 Bundle 加载
            return Bundle.main.url(forResource: fileName, withExtension: "svg")
        }

        // 自定义主题：从主题目录加载
        let themeDir = Self.customThemesDir.appendingPathComponent(currentThemeId)
        let svgURL = themeDir.appendingPathComponent("\(fileName).svg")
        if FileManager.default.fileExists(atPath: svgURL.path) {
            return svgURL
        }

        // 回退到内置主题
        return Bundle.main.url(forResource: fileName, withExtension: "svg")
    }

    /// 获取状态对应的 SVG 文件名（不含扩展名）
    private func svgFileName(for state: NotchikkoState) -> String {
        // 先检查自定义主题的 manifest 映射
        if currentThemeId != Self.builtinThemeId,
           let mapping = loadManifest(for: currentThemeId)?.animations,
           let custom = mapping[state.rawValue] {
            return custom
        }

        // 默认映射（内置 clawd 主题）
        return state.svgName
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
