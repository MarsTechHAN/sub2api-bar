import Foundation

/// 命令行入口：配置和自检用，不启动界面。
enum CLI {

    static let usage = """
    Sub2API Quota — sub2api 配额菜单栏

    用法:
      Sub2APIQuota                                  启动菜单栏（默认）
      Sub2APIQuota --endpoint <URL> --api-key <KEY> [--account-id N]
                                                    写入配置后退出
      Sub2APIQuota --dump                           用当前配置打一遍接口并打印结果
      Sub2APIQuota --accounts                       列出服务上的账号
      Sub2APIQuota --help
    """

    /// 处理完命令行参数返回 true 表示“已经干完活了，不要再起界面”。
    static func run(_ args: [String]) -> Bool {
        var opts: [String: String] = [:]
        var flags: Set<String> = []
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { i += 1; continue }
            let name = String(a.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                opts[name] = args[i + 1]
                i += 2
            } else {
                flags.insert(name)
                i += 1
            }
        }

        if flags.contains("help") || flags.contains("h") {
            print(usage)
            return true
        }

        if opts["endpoint"] != nil || opts["api-key"] != nil || opts["account-id"] != nil {
            if let e = opts["endpoint"] { Settings.shared.endpoint = e }
            if let k = opts["api-key"] { Settings.shared.apiKey = k }
            if let id = opts["account-id"].flatMap(Int.init) { Settings.shared.accountID = id }
            print("已保存到 \(Settings.fileURL.path)")
            print("  服务地址   \(Settings.shared.endpoint)")
            print("  API Key    \(mask(Settings.shared.apiKey))")
            print("  账号 ID    \(Settings.shared.accountID == 0 ? "未选择（首次刷新时自动选）" : "\(Settings.shared.accountID)")")
            return true
        }

        if flags.contains("dump") { dump(); return true }
        if flags.contains("accounts") { listAccounts(); return true }

        return false
    }

    private static func mask(_ s: String) -> String {
        guard s.count > 12 else { return s.isEmpty ? "(未设置)" : "****" }
        return s.prefix(8) + "…" + s.suffix(4)
    }

    /// 顶层代码里没有 async 上下文，用信号量把异步结果等回来。
    private static func sync<T>(_ body: @escaping @Sendable () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.value = await body()
            sem.signal()
        }
        sem.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable { var value: T? }

    private static func requireConfig() -> (String, String)? {
        let s = Settings.shared
        guard s.isConfigured else {
            FileHandle.standardError.write(Data(
                "未配置。先跑一次 --endpoint <URL> --api-key <KEY>，或直接编辑 \(Settings.fileURL.path)\n".utf8))
            return nil
        }
        return (s.endpoint, s.apiKey)
    }

    private static func dump() {
        guard let (endpoint, key) = requireConfig() else { exit(1) }
        let s = Settings.shared
        let accountID = s.accountID, cycleMode = s.cycleMode
        let result = sync {
            await SnapshotLoader.load(endpoint: endpoint, apiKey: key,
                                      accountID: accountID, cycleMode: cycleMode, force: false)
        }
        print(Report.full(result.snapshot))
        print("")
        print("── 菜单栏显示 ──")
        let mode = s.displayMode
        let primary: UsageWindow? = {
            switch mode {
            case .auto: return result.snapshot.usage.hottest
            case .window(let k): return result.snapshot.usage.window(key: k) ?? result.snapshot.usage.hottest
            }
        }()
        if let w = primary {
            var parts: [String] = []
            if s.showLabel { parts.append(w.shortLabel) }
            parts.append(Fmt.percent(w.utilization))
            // 真身是一个环形模板图像，终端画不出来，用方块条示意一下
            let icon = s.showGauge ? Fmt.gauge(w.utilization, segments: 5) + " " : ""
            print("  \(icon)[\(parts.joined(separator: " "))]   (模式: \(mode.rawValue))")
        } else {
            print("  [⚠]")
        }
        if result.snapshot.errorMessage != nil { exit(2) }
    }

    private static func listAccounts() {
        guard let (endpoint, key) = requireConfig() else { exit(1) }
        let client = APIClient(endpoint: endpoint, apiKey: key)
        let accounts = sync { (try? await client.fetchAccounts()) ?? [] }
        if accounts.isEmpty {
            print("没读到账号（检查地址和 API Key）")
            exit(1)
        }
        let current = Settings.shared.accountID
        for a in accounts {
            print("\(a.id == current ? "*" : " ") \(Fmt.padLeft("\(a.id)", 4))  \(Fmt.pad(a.displayName, 22)) \(a.subtitle)")
        }
    }
}
