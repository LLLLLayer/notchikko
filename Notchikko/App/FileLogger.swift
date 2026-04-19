import Foundation

/// 日志等级（grep 友好的大写枚举值）
enum LogLevel: String {
    case error = "ERROR"
    case warn  = "WARN"
    case info  = "INFO"
    case debug = "DEBUG"
}

/// 文件日志系统：写入 ~/Library/Logs/Notchikko/notchikko-YYYY-MM-DD.log，保留 3 天
///
/// 行格式：`YYYY-MM-DD HH:mm:ss.SSS LEVEL [Tag] sid=xxxxxxxx req=xxxxxxxx message`
/// - 等级 LEVEL 便于 `grep ERROR` 一键筛查
/// - sid / req 为 session_id / request_id 的前 8 位；hook 侧日志也用同样格式，方便跨端 grep
final class FileLogger {
    static let shared = FileLogger()

    private let logDir: URL
    private let dateFormatter: DateFormatter
    private let timestampFormatter: DateFormatter
    private let retentionDays = 3
    private let queue = DispatchQueue(label: "com.notchikko.logger", qos: .utility)
    private var fileHandle: FileHandle?
    private var currentDateString: String = ""

    private init() {
        logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Notchikko")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        purgeOldLogs()
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Public

    func log(_ message: String,
             tag: String = "",
             level: LogLevel = .info,
             sid: String? = nil,
             req: String? = nil,
             file: String = #file,
             line: Int = #line) {
        let timestamp = timestampFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let tagStr = tag.isEmpty ? "\(fileName):\(line)" : tag

        var entry = "\(timestamp) \(level.rawValue) [\(tagStr)]"
        if let sid, !sid.isEmpty { entry += " sid=\(Self.shortId(sid))" }
        if let req, !req.isEmpty { entry += " req=\(Self.shortId(req))" }
        entry += " \(message)\n"

        queue.async { [weak self] in
            self?.write(entry)
        }

        #if DEBUG
        print(entry, terminator: "")
        #endif
    }

    /// 从 UUID/session_id 里取前 8 位用于日志显示（与 hook 侧一致）
    static func shortId(_ id: String) -> String {
        let head = id.split(separator: "-").first.map(String.init) ?? id
        return String(head.prefix(8))
    }

    /// 返回日志目录路径（Settings 里展示用）
    var logDirectoryPath: String {
        logDir.path
    }

    /// 同步 flush：等待所有排队写入完成 + fsync 到磁盘。
    /// applicationWillTerminate 调用，避免最后 N 条日志丢失。
    func flush() {
        queue.sync {
            try? fileHandle?.synchronize()
        }
    }

    // MARK: - Private

    private func write(_ entry: String) {
        let today = dateFormatter.string(from: Date())

        // 日期变了 → 切换文件
        if today != currentDateString {
            fileHandle?.closeFile()
            fileHandle = nil
            currentDateString = today
        }

        if fileHandle == nil {
            let fileURL = logDir.appendingPathComponent("notchikko-\(currentDateString).log")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: fileURL)
            fileHandle?.seekToEndOfFile()
        }

        if let data = entry.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    private func purgeOldLogs() {
        queue.async { [weak self] in
            guard let self else { return }
            let cutoff = Calendar.current.date(byAdding: .day, value: -self.retentionDays, to: Date()) ?? Date()
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: self.logDir, includingPropertiesForKeys: [.creationDateKey]
            ) else { return }

            for file in files {
                guard file.pathExtension == "log" else { continue }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                   let created = attrs[.creationDate] as? Date,
                   created < cutoff {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }
}

// MARK: - 便捷全局函数

/// 全局日志函数：`Log("message", tag: "Module", level: .error, sid: sid, req: req)`
/// 旧的 `Log("msg", tag: "X")` 调用自动走 `.info`，向后兼容。
func Log(_ message: String,
         tag: String = "",
         level: LogLevel = .info,
         sid: String? = nil,
         req: String? = nil,
         file: String = #file,
         line: Int = #line) {
    FileLogger.shared.log(message, tag: tag, level: level, sid: sid, req: req, file: file, line: line)
}
