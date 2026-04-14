import AVFoundation
import Foundation

/// 管理状态转场音效，支持内置 + 自定义音效
@MainActor
final class SoundManager {
    static let shared = SoundManager()

    /// 需要播放音效的状态转场
    static let soundableStates: [String] = [
        "happy", "error", "approving", "session-start",
    ]

    /// 内置音效映射: state → bundle 资源名 (不含扩展名)
    private let defaultSoundMap: [String: String] = [
        "happy": "sfx-happy",
        "error": "sfx-error",
        "approving": "sfx-approval",
        "session-start": "sfx-session-start",
    ]

    /// 自定义音效目录
    private let customSoundsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notchikko/sounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var currentPlayer: AVAudioPlayer?

    /// 冷却：同一状态 2 秒内不重复播放
    private var lastPlayTimes: [String: Date] = [:]
    private static let cooldownInterval: TimeInterval = 2.0

    private init() {}

    // MARK: - 播放

    /// 根据状态名播放对应音效（带冷却 + fallback）
    func play(for stateName: String) {
        let prefs = PreferencesStore.shared.preferences
        guard prefs.soundVolume > 0 else { return }

        // 冷却检查：同一状态 2 秒内不重复播放
        let now = Date()
        if let lastTime = lastPlayTimes[stateName],
           now.timeIntervalSince(lastTime) < Self.cooldownInterval {
            return
        }
        lastPlayTimes[stateName] = now

        let volume = prefs.soundVolume

        // 优先级：自定义音效 → 主题音效 → 内置音效
        if let url = customSoundURL(for: stateName, prefs: prefs) {
            playURL(url, volume: volume)
            return
        }

        if let url = themeSoundURL(for: stateName) {
            playURL(url, volume: volume)
            return
        }

        if let url = builtinSoundURL(for: stateName) {
            playURL(url, volume: volume)
        }
    }

    // MARK: - 自定义音效管理

    /// 导入自定义音效文件，返回存储后的文件名
    func importCustomSound(from sourceURL: URL, for stateName: String) throws -> String {
        let ext = sourceURL.pathExtension
        let fileName = "custom-\(stateName).\(ext)"
        let destURL = customSoundsDir.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        return fileName
    }

    /// 删除自定义音效
    func removeCustomSound(for stateName: String) {
        let prefs = PreferencesStore.shared.preferences
        guard let fileName = prefs.customSounds[stateName] else { return }
        let url = customSoundsDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    /// 检查某状态是否有内置音效
    func hasBuiltinSound(for stateName: String) -> Bool {
        builtinSoundURL(for: stateName) != nil
    }

    // MARK: - Sound URL Resolution (三级 fallback)

    /// 用户自定义音效
    private func customSoundURL(for stateName: String, prefs: NotchikkoPreferences) -> URL? {
        guard let customFile = prefs.customSounds[stateName] else { return nil }
        let url = customSoundsDir.appendingPathComponent(customFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 当前主题的音效
    /// 优先用 theme.json 的 sounds 映射，fallback 到目录扫描 sounds/{stateName}.{ext}
    private func themeSoundURL(for stateName: String) -> URL? {
        let themeId = PreferencesStore.shared.preferences.themeId
        guard themeId != ThemeProvider.builtinThemeId else { return nil }

        let themeBaseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchikko/themes/\(themeId)")
        let soundsDir = themeBaseDir.appendingPathComponent("sounds")

        // 1. manifest.sounds 映射（theme.json 指定的文件名）
        let manifestURL = themeBaseDir.appendingPathComponent("theme.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(ThemeManifest.self, from: data),
           let fileName = manifest.sounds?[stateName] {
            let url = soundsDir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // 2. 目录扫描 fallback（按约定文件名搜索）
        guard FileManager.default.fileExists(atPath: soundsDir.path) else { return nil }
        for ext in ["wav", "mp3", "aiff", "m4a"] {
            let url = soundsDir.appendingPathComponent("\(stateName).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// 内置音效（bundle 资源）
    private func builtinSoundURL(for stateName: String) -> URL? {
        guard let bundleName = defaultSoundMap[stateName] else { return nil }
        return Bundle.main.url(forResource: bundleName, withExtension: "wav")
    }

    // MARK: - Playback

    private func playURL(_ url: URL, volume: Float) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = volume
        player.play()
        currentPlayer = player  // 防止被 ARC 回收
    }
}
