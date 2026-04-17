import Foundation

/// 文件日志系统：写入 ~/Library/Logs/Notchikko/notchikko-YYYY-MM-DD.log，保留 3 天
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
        timestampFormatter.dateFormat = "HH:mm:ss.SSS"

        purgeOldLogs()
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Public

    func log(_ message: String, tag: String = "", file: String = #file, line: Int = #line) {
        let timestamp = timestampFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let prefix = tag.isEmpty ? "[\(fileName):\(line)]" : "[\(tag)]"
        let entry = "\(timestamp) \(prefix) \(message)\n"

        queue.async { [weak self] in
            self?.write(entry)
        }

        #if DEBUG
        // Debug 模式同时输出到 stdout
        print(entry, terminator: "")
        #endif
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

/// 全局日志函数：`Log("message", tag: "Module")`
func Log(_ message: String, tag: String = "", file: String = #file, line: Int = #line) {
    FileLogger.shared.log(message, tag: tag, file: file, line: line)
}
