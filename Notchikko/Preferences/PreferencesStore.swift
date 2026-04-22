import Foundation

@MainActor @Observable
final class PreferencesStore {
    static let shared = PreferencesStore()
    static let didChangeNotification = Notification.Name("NotchikkoPreferencesDidChange")

    var preferences: NotchikkoPreferences {
        didSet {
            let needsRefresh = oldValue.petScale != preferences.petScale
                || oldValue.themeId != preferences.themeId
                || oldValue.notchDetectionMode != preferences.notchDetectionMode
            // 累积 notifyUI：debounce 窗口内只要有一次 true，最终写盘就要通知 UI rebuild
            pendingNotifyUI = pendingNotifyUI || needsRefresh
            scheduleSave()
        }
    }

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private var pendingNotifyUI: Bool = false

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notchikko")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("preferences.json")

        if let data = try? Data(contentsOf: fileURL),
           let prefs = try? JSONDecoder().decode(NotchikkoPreferences.self, from: data) {
            preferences = prefs
        } else {
            preferences = NotchikkoPreferences()
        }
    }

    /// 防抖保存：100ms 内多次修改只写盘一次。
    /// pendingNotifyUI 跨 debounce 窗口累积，避免后续 notifyUI=false 的修改覆盖前面 true 的修改。
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let shouldNotify = pendingNotifyUI
            pendingNotifyUI = false
            persist(notifyUI: shouldNotify)
        }
    }

    /// 立即写盘 + 发通知
    func save() {
        saveTask?.cancel()
        pendingNotifyUI = false
        persist(notifyUI: true)
    }

    private func persist(notifyUI: Bool) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(preferences) else { return }
        try? data.write(to: fileURL, options: .atomic)
        if notifyUI {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}

// MARK: - 数据模型

enum NotchDetectionMode: String, Codable, CaseIterable {
    case auto
    case forceOn
    case forceOff
}

enum AppLanguage: String, Codable, CaseIterable {
    case system
    case en
    case zhHans = "zh-Hans"

    /// `nil` → remove AppleLanguages override, fall back to system locale.
    var appleLanguagesValue: [String]? {
        switch self {
        case .system: return nil
        case .en: return ["en"]
        case .zhHans: return ["zh-Hans"]
        }
    }
}

struct NotchikkoPreferences: Codable, Equatable {
    var petScale: CGFloat = 1.5
    var soundVolume: Float = 0.3          // 0.0 = 静音, 1.0 = 最大
    var soundThemeId: String = "arcade"   // 声音主题
    var customSounds: [String: String] = [:]
    var approvalCardHideDelay: TimeInterval = 15
    var approvalCardEnabled: Bool = false
    var installedHooks: [String: Bool] = [:]
    var themeId: String = "clawd"
    var notchDetectionMode: NotchDetectionMode = .auto
    var danmakuEnabled: Bool = true
    var hasShownHookPrompt: Bool = false
    var language: AppLanguage = .system
}

// MARK: - 语言覆盖（提前于 PreferencesStore 初始化调用）

/// 写 UserDefaults 的 AppleLanguages 来强制 App 使用指定语言。
/// 切回 .system 会移除覆盖，让系统 locale 接管。
func applyAppLanguage(_ language: AppLanguage) {
    if let value = language.appleLanguagesValue {
        UserDefaults.standard.set(value, forKey: "AppleLanguages")
    } else {
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    }
}

/// 直接从磁盘读 preferences.json 取出 language 并应用。
/// 绕过 @MainActor PreferencesStore，供 NotchikkoApp.init 在任何 SwiftUI 字符串解析之前调用。
func applyAppLanguageFromDisk() {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("notchikko")
    let url = dir.appendingPathComponent("preferences.json")
    guard let data = try? Data(contentsOf: url),
          let prefs = try? JSONDecoder().decode(NotchikkoPreferences.self, from: data) else {
        return
    }
    applyAppLanguage(prefs.language)
}

/// 声音主题
struct SoundTheme: Identifiable {
    let id: String
    let name: String
}

/// 内置声音主题列表
enum SoundThemeRegistry {
    static let themes: [SoundTheme] = [
        SoundTheme(id: "arcade", name: String(localized: "sound.theme.arcade")),
    ]
}

// 保留 SoundVolume 用于向后兼容旧 preferences.json
enum SoundVolume: String, Codable, CaseIterable {
    case mute, low, medium, high

    var floatValue: Float {
        switch self {
        case .mute: return 0
        case .low: return 0.15
        case .medium: return 0.30
        case .high: return 0.50
        }
    }
}
