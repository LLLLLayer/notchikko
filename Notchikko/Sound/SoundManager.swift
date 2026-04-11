import AVFoundation
import Foundation

/// 管理状态转场音效，支持内置 + 自定义音效
final class SoundManager {
    static let shared = SoundManager()

    /// 需要播放音效的状态转场
    static let soundableStates: [String] = [
        "happy", "error", "thinking", "approving", "nod", "shake",
    ]

    /// 内置音效映射: state → bundle 资源名 (不含扩展名)
    private let defaultSoundMap: [String: String] = [
        "happy": "sfx-happy",
        "error": "sfx-error",
        "thinking": "sfx-thinking",
        "approving": "sfx-approval",
        "nod": "sfx-approve",
        "shake": "sfx-deny",
    ]

    /// 自定义音效目录
    private let customSoundsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notchikko/sounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var currentPlayer: AVAudioPlayer?

    private init() {}

    // MARK: - 播放

    /// 根据状态名播放对应音效
    func play(for stateName: String) {
        let prefs = PreferencesStore.shared.preferences
        guard prefs.soundVolume != .mute else { return }

        // 优先自定义音效
        if let customFile = prefs.customSounds[stateName] {
            let url = customSoundsDir.appendingPathComponent(customFile)
            if FileManager.default.fileExists(atPath: url.path) {
                playURL(url, volume: prefs.soundVolume.floatValue)
                return
            }
        }

        // 内置音效
        if let bundleName = defaultSoundMap[stateName],
           let url = Bundle.main.url(forResource: bundleName, withExtension: "wav") {
            playURL(url, volume: prefs.soundVolume.floatValue)
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
        guard let bundleName = defaultSoundMap[stateName] else { return false }
        return Bundle.main.url(forResource: bundleName, withExtension: "wav") != nil
    }

    // MARK: - Private

    private func playURL(_ url: URL, volume: Float) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.volume = volume
        player.play()
        currentPlayer = player  // 防止被 ARC 回收
    }
}
