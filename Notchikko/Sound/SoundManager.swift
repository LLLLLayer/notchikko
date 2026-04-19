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

    /// 按 URL 缓存的 AVAudioPlayer。
    /// 保持 player 实例存活 → AudioQueue 不释放 → CoreAudio HAL 连接保持热态，
    /// 下一次同 URL 播放仅需 `currentTime = 0 + play()` 两个主线程 syscall。
    private var cachedPlayers: [URL: AVAudioPlayer] = [:]

    /// 冷却：同一状态 2 秒内不重复播放
    private var lastPlayTimes: [String: Date] = [:]
    private static let cooldownInterval: TimeInterval = 2.0

    private init() {}

    // MARK: - Prewarm

    /// 启动期调用一次：后台预载所有内置 `sfx-*.wav`，触发 CoreAudio HAL 冷启 +
    /// AVFoundation 符号绑定，把首次用户可见播放的主线程成本从 ~50–200ms 降到接近零。
    ///
    /// **关键时序**：
    /// 1. `sfx-session-start.wav` 排在最前（启动期第一个要播的就是它）
    /// 2. 它一加载完**立即**静音 play() 激活 HAL——不等剩下 12 个文件
    /// 3. 其余 sfx 后台慢慢装，不在关键路径上
    ///
    /// 为什么必须立即 HAL 激活：某些 macOS 版本 `prepareToPlay()` 并不真正打开输出单元，
    /// 只有 `play()` 才触发。把 HAL 激活放在 prewarm 末尾曾经让 session-start 在 HAL
    /// 冷态下 cache 命中 play()，仍阻塞主线程 60-130ms。
    func prewarm() {
        let t0 = Date()
        Log("prewarm start", tag: "Sound")
        Task.detached(priority: .userInitiated) { [weak self] in
            // session-start 排首位，其余按字典序
            let urls = Self.builtinSoundURLs().sorted { a, b in
                let aKey = a.lastPathComponent == "sfx-session-start.wav" ? "\u{0}" : a.lastPathComponent
                let bKey = b.lastPathComponent == "sfx-session-start.wav" ? "\u{0}" : b.lastPathComponent
                return aKey < bKey
            }
            var halWarmed = false
            var loaded = 0
            for url in urls {
                let tFile = Date()
                guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
                player.prepareToPlay()
                let fileMs = Int(Date().timeIntervalSince(tFile) * 1000)
                await self?.installPrewarmed(url: url, box: UncheckedBox(value: player))
                loaded += 1
                if fileMs > 20 {
                    Log("prewarm slow file \(url.lastPathComponent) \(fileMs)ms", tag: "Sound")
                }
                // 首个加载完成后立刻激活 HAL——不等其他文件
                if !halWarmed {
                    halWarmed = true
                    let tHAL = Date()
                    player.volume = 0
                    player.play()
                    try? await Task.sleep(for: .milliseconds(30))
                    player.stop()
                    player.currentTime = 0
                    let halMs = Int(Date().timeIntervalSince(tHAL) * 1000)
                    Log("prewarm HAL ready in \(halMs)ms (file=\(url.lastPathComponent))", tag: "Sound")
                }
            }
            let totalMs = Int(Date().timeIntervalSince(t0) * 1000)
            Log("prewarm done: \(loaded) files, total \(totalMs)ms", tag: "Sound")
        }
    }

    private func installPrewarmed(url: URL, box: UncheckedBox<AVAudioPlayer>) {
        // 期间可能已经被懒加载塞过，那条路径更新鲜（带过音量），保留它
        if cachedPlayers[url] == nil {
            cachedPlayers[url] = box.value
        }
    }

    /// 枚举 bundle 资源里所有以 `sfx-` 开头的 WAV。
    /// `nonisolated` 因为要从 `prewarm()` 的 detached Task 里调用，和 @MainActor 隔离无关。
    private nonisolated static func builtinSoundURLs() -> [URL] {
        guard let resourceURL = Bundle.main.resourceURL,
              let enumerator = FileManager.default.enumerator(
                  at: resourceURL,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "wav",
                  url.lastPathComponent.hasPrefix("sfx-") else { continue }
            urls.append(url)
        }
        return urls
    }

    // MARK: - 播放

    /// 根据状态名播放对应音效（带冷却 + fallback）
    /// - Parameter cooldownKey: 自定义冷却键。多 agent 场景下传 sessionId 避免并发吞声；
    ///   不传则按 stateName 去重（同状态 2s 内不重复）。
    func play(for stateName: String, cooldownKey: String? = nil) {
        let prefs = PreferencesStore.shared.preferences
        guard prefs.soundVolume > 0 else { return }

        // 冷却检查：默认按状态名去重 2s；多 agent 并发可传 sessionId 拓宽
        let key = cooldownKey ?? stateName
        let now = Date()
        if let lastTime = lastPlayTimes[key],
           now.timeIntervalSince(lastTime) < Self.cooldownInterval {
            return
        }
        lastPlayTimes[key] = now

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

        // URL 路径不变但底层文件已替换，旧 player 指向的 buffer 是陈旧的
        invalidate(url: destURL)
        return fileName
    }

    /// 删除自定义音效
    func removeCustomSound(for stateName: String) {
        let prefs = PreferencesStore.shared.preferences
        guard let fileName = prefs.customSounds[stateName] else { return }
        let url = customSoundsDir.appendingPathComponent(fileName)
        invalidate(url: url)
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
    /// defaultSoundMap 显式映射优先；未映射的键默认按 `sfx-<stateName>` 查找（供 combo 变体如 petting-1..8 用）
    private func builtinSoundURL(for stateName: String) -> URL? {
        let bundleName = defaultSoundMap[stateName] ?? "sfx-\(stateName)"
        return Bundle.main.url(forResource: bundleName, withExtension: "wav")
    }

    // MARK: - Playback

    private func playURL(_ url: URL, volume: Float) {
        let t0 = Date()
        let hit: String
        let player: AVAudioPlayer
        if let cached = cachedPlayers[url] {
            hit = "hit"
            player = cached
        } else {
            // Cache miss：prewarm 未覆盖（theme / custom URL）或尚未跑到；走懒加载
            // 首次命中的主线程开销 = AVAudioPlayer 实例化 + prepareToPlay，同状态 2s cooldown 保证只发生 1 次
            hit = "miss"
            guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else {
                Log("play FAIL \(url.lastPathComponent)", tag: "Sound")
                return
            }
            newPlayer.prepareToPlay()
            cachedPlayers[url] = newPlayer
            player = newPlayer
        }

        player.volume = volume
        // 重置到开头，让连按同一音效每次都从头播；
        // AVAudioPlayer 对 currentTime=0 的处理是直接跳播头，比 stop()+play() 柔和得多。
        player.currentTime = 0
        player.play()
        // Why 不再 stop() 旧 player：在正在渲染的 player 上 stop() 会在非零交叉点硬切波形，
        // 输出 pop/click（petting combo 连环切换 = 电流炸麦）。让多 player 自然叠混更干净——
        // AVAudioPlayer 的底层 AudioUnit mixer 会正确求和。同状态的 2s cooldown 限制了叠响量。
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        Log("play \(url.lastPathComponent) [\(hit)] \(ms)ms", tag: "Sound")
    }

    /// 使 URL 对应的缓存失效（自定义音效文件替换 / 删除后）
    private func invalidate(url: URL) {
        guard let stale = cachedPlayers.removeValue(forKey: url) else { return }
        stale.stop()
    }
}

/// 跨越 actor 边界传递非 Sendable 引用类型的安全壳。
/// 用于 `prewarm()` 从 detached Task 把 AVAudioPlayer 交回 MainActor 安装。
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}
