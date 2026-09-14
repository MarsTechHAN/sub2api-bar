import Foundation

/// 菜单栏 app 没有 stdout 可看，运行日志写到 ~/.config/sub2api-quota/app.log。
enum Log {
    static let fileURL = Settings.directory.appendingPathComponent("app.log")
    private static let queue = DispatchQueue(label: "run.hanxiao.sub2api-quota.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: Settings.directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: fileURL) {
                defer { try? h.close() }
                // 超过 1MB 就从头写，省得无限长
                let size = (try? h.seekToEnd()) ?? 0
                if size > 1_000_000 {
                    try? h.truncate(atOffset: 0)
                    try? h.seek(toOffset: 0)
                }
                try? h.write(contentsOf: data)
            } else {
                fm.createFile(atPath: fileURL.path, contents: data,
                              attributes: [.posixPermissions: 0o600])
            }
        }
    }
}
