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
            scheduleSave(notifyUI: needsRefresh)
        }
    }

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

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

    /// 防抖保存：100ms 内多次修改只写盘一次
    private func scheduleSave(notifyUI: Bool) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            persist(notifyUI: notifyUI)
        }
    }

    /// 立即写盘 + 发通知
    func save() {
        saveTask?.cancel()
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

struct NotchikkoPreferences: Codable, Equatable {
    var petScale: CGFloat = 1.5
    var soundVolume: Float = 0.3          // 0.0 = 静音, 1.0 = 最大
    var soundThemeId: String = "arcade"   // 声音主题
    var customSounds: [String: String] = [:]
    var approvalCardHideDelay: TimeInterval = 5
    var approvalCardEnabled: Bool = false
    var installedHooks: [String: Bool] = [:]
    var themeId: String = "clawd"
    var notchDetectionMode: NotchDetectionMode = .auto
    var danmakuEnabled: Bool = true
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
