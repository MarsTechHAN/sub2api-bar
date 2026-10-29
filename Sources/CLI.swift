import Foundation

/// 命令行入口：配置和自检用，不启动界面。
enum CLI {

    static let usage = """
    Sub2API Quota — sub2api 配额菜单栏

    用法:
      Sub2APIQuota                                  启动菜单栏（默认）
      Sub2APIQuota --endpoint <URL> --api-key <KEY> [--account-id N]
                                                    写入配置后退出
      Sub2APIQuota --login                          用环境变量 SUB2API_ADMIN_EMAIL /
                                                    SUB2API_ADMIN_PASSWORD 登录管理员账号
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
            if let k = opts["api-key"] {
                Settings.shared.apiKey = k
                Settings.shared.authMode = .apiKey
            }
            if let id = opts["account-id"].flatMap(Int.init) { Settings.shared.accountID = id }
            print("已保存到 \(Settings.fileURL.path)")
            print("  服务地址   \(Settings.shared.endpoint)")
            print("  API Key    \(mask(Settings.shared.apiKey))")
            print("  账号 ID    \(Settings.shared.accountID == 0 ? "未选择（首次刷新时自动选）" : "\(Settings.shared.accountID)")")
            return true
        }

        if flags.contains("login") { login(); return true }
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

    private static func requireConfig() -> Bool {
        let s = Settings.shared
        guard s.isConfigured else {
            FileHandle.standardError.write(Data(
                "未配置。先跑一次 --endpoint <URL> --api-key <KEY>，或在图形界面里登录，或直接编辑 \(Settings.fileURL.path)\n".utf8))
            return false
        }
        return true
    }

    /// 无界面登录，方便脚本初始化。密码只从环境变量读，不写进配置。
    private static func login() {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["SUB2API_ADMIN_EMAIL"], !email.isEmpty,
              let password = env["SUB2API_ADMIN_PASSWORD"], !password.isEmpty else {
            FileHandle.standardError.write(Data(
                "用法：SUB2API_ADMIN_EMAIL=you@example.com SUB2API_ADMIN_PASSWORD=… Sub2APIQuota --login\n".utf8))
            exit(1)
        }
        let endpoint = Settings.shared.endpoint
        guard !endpoint.isEmpty else {
            FileHandle.standardError.write(Data("请先用 --endpoint 配置服务地址\n".utf8))
            exit(1)
        }
        let outcome: Result<LoginOutcome, Error> = sync {
            do { return .success(try await AuthManager.login(endpoint: endpoint,
                                                             email: email, password: password)) }
            catch { return .failure(error) }
        }
        switch outcome {
        case .failure(let error):
            FileHandle.standardError.write(Data(
                "登录失败：\(SnapshotLoader.message(for: error))\n".utf8))
            exit(1)
        case .success(.needs2FA):
            FileHandle.standardError.write(Data(
                "该账号启用了两步验证，请用图形界面登录（菜单栏 → 设置…）\n".utf8))
            exit(1)
        case .success(.tokens):
            Settings.shared.authMode = .login
            Settings.shared.adminEmail = email
            print("登录成功，令牌已保存到 \(Settings.fileURL.path)")
        }
    }

    private static func dump() {
        guard requireConfig() else { exit(1) }
        let s = Settings.shared
        let result = sync {
            await SnapshotLoader.loadConfigured(force: false)
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
        if result.snapshot.errorMessage != nil || result.snapshot.usage.error != nil { exit(2) }
    }

    private static func listAccounts() {
        guard requireConfig() else { exit(1) }
        let endpoint = Settings.shared.endpoint
        let accounts = sync { () -> [Account] in
            do {
                let auth = try await AuthManager.currentAuth(endpoint: endpoint)
                return try await APIClient(endpoint: endpoint, auth: auth).fetchAccounts()
            } catch {
                FileHandle.standardError.write(Data(
                    "读取失败：\(SnapshotLoader.message(for: error))\n".utf8))
                return []
            }
        }
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
