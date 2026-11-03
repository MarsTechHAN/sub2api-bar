import Foundation

/// 命令行入口：配置和自检用，不启动界面。
enum CLI {

    static let usage = """
    Sub2API Quota — sub2api 配额菜单栏

    用法:
      Sub2APIQuota                                  启动菜单栏（默认）
      Sub2APIQuota [--server <名称|序号>] --endpoint <URL> --api-key <KEY> [--account-id N[,M…]]
                                                    写入配置后退出；--server 指定的服务器
                                                    不存在时新建一台，省略时改第一台
      Sub2APIQuota [--server …] --login             用环境变量 SUB2API_ADMIN_EMAIL /
                                                    SUB2API_ADMIN_PASSWORD 登录管理员账号
      Sub2APIQuota --dump                           打一遍所有服务器的接口并打印结果
      Sub2APIQuota [--server …] --accounts          列出服务上的账号
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

        // 有动作时，--endpoint / --api-key / --account-id 作为这次动作的配置先应用。
        // 否则 `--endpoint ... --login` 会只写完配置就把 --login 静默吞掉。
        let action: String? = flags.contains("login") ? "login"
            : flags.contains("dump") ? "dump"
            : flags.contains("accounts") ? "accounts"
            : nil
        if let action {
            applyOverrides(opts)
            switch action {
            case "login": login()
            case "dump": dump()
            default: listAccounts()
            }
            return true
        }

        if opts["endpoint"] != nil || opts["api-key"] != nil || opts["account-id"] != nil {
            applyOverrides(opts)
            guard let srv = target else { return true }
            print("已保存到 \(Settings.fileURL.path)")
            print("  服务器     \(srv.displayName)")
            print("  服务地址   \(srv.endpoint)")
            print("  API Key    \(mask(srv.apiKey))")
            let ids = srv.accounts.map { "\($0.id)" }.joined(separator: ", ")
            print("  监控账号   \(ids.isEmpty ? "未选择（首次刷新时自动选）" : ids)")
            return true
        }

        return false
    }

    /// 这次命令操作的服务器 id，由 --server 决定
    private static var targetID: String?
    private static var target: ServerConfig? { targetID.flatMap { Settings.shared.server($0) } }

    /// --server 按名称或从 1 开始的序号找；找不到且要写配置时新建一台，用它当名称。
    private static func resolveTarget(_ selector: String?, create: Bool) -> ServerConfig? {
        let servers = Settings.shared.servers
        guard let selector else {
            if let first = servers.first { return first }
            return create ? Settings.shared.addServer() : nil
        }
        if let n = Int(selector), n >= 1, n <= servers.count { return servers[n - 1] }
        if let hit = servers.first(where: { $0.name == selector || $0.displayName == selector }) { return hit }
        guard create else { return nil }
        let created = Settings.shared.addServer()
        Settings.shared.updateServer(created.id) { $0.name = selector }
        return Settings.shared.server(created.id)
    }

    private static func applyOverrides(_ opts: [String: String]) {
        let writes = opts["endpoint"] != nil || opts["api-key"] != nil || opts["account-id"] != nil
        guard let srv = resolveTarget(opts["server"], create: writes) else {
            if let sel = opts["server"] {
                FileHandle.standardError.write(Data("找不到服务器：\(sel)\n".utf8))
                exit(1)
            }
            return
        }
        targetID = srv.id
        Settings.shared.updateServer(srv.id) { s in
            if let e = opts["endpoint"] { s.endpoint = e }
            if let k = opts["api-key"] {
                s.apiKey = k.trimmingCharacters(in: .whitespacesAndNewlines)
                s.authMode = .apiKey
            }
        }
        // 逗号分隔可以一次监控多个账号；没列出来的停止监控
        if let raw = opts["account-id"] {
            let ids = raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            for t in srv.accounts where !ids.contains(t.id) { Settings.shared.setTracked(t.id, false, serverID: srv.id) }
            for id in ids { Settings.shared.setTracked(id, true, serverID: srv.id) }
        }
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
        guard Settings.shared.isConfigured else {
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
        guard let srv = target, !srv.endpoint.isEmpty else {
            FileHandle.standardError.write(Data("请先用 --endpoint 配置服务地址\n".utf8))
            exit(1)
        }
        let outcome: Result<LoginOutcome, Error> = sync {
            do { return .success(try await AuthManager.login(serverID: srv.id, endpoint: srv.endpoint,
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
            Settings.shared.updateServer(srv.id) {
                $0.authMode = .login
                $0.adminEmail = email
            }
            print("登录成功（\(srv.displayName)），令牌已保存到 \(Settings.fileURL.path)")
        }
    }

    private static func dump() {
        guard requireConfig() else { exit(1) }
        let s = Settings.shared
        let servers = s.configuredServers
        var failed = false
        var first = true
        for srv in servers {
            let result = sync { await SnapshotLoader.load(serverID: srv.id) }
            let snapshots = result.errorMessage.map { e -> [Snapshot] in
                var snap = Snapshot()
                snap.errorMessage = e
                return [snap]
            } ?? result.snapshots
            for snap in snapshots {
                if !first { print("\n" + String(repeating: "─", count: 40) + "\n") }
                first = false
                print(Report.full(snap, serverName: servers.count > 1 ? srv.displayName : nil))
                print("")
                print("── 菜单栏显示 ──")
                let mode = s.displayMode
                let primary: UsageWindow? = {
                    switch mode {
                    case .auto: return snap.usage.hottest
                    case .window(let k): return snap.usage.window(key: k) ?? snap.usage.hottest
                    }
                }()
                if let w = primary {
                    var parts: [String] = []
                    if s.showLabel { parts.append(w.shortLabel) }
                    parts.append(Fmt.percent(w.utilization))
                    // 真身是一个环形图像，终端画不出来，用方块条示意一下
                    let icon = s.showGauge ? Fmt.gauge(w.utilization, segments: 5) + " " : ""
                    let color = srv.tracked(snap.accountID).map { "  颜色: \($0.color)" } ?? ""
                    print("  \(icon)[\(parts.joined(separator: " "))]   (模式: \(mode.rawValue))\(color)")
                } else {
                    print("  [⚠]")
                }
                if snap.errorMessage != nil || snap.usage.error != nil { failed = true }
            }
        }
        if failed { exit(2) }
    }

    private static func listAccounts() {
        guard requireConfig() else { exit(1) }
        guard let srv = target, srv.isConfigured else {
            FileHandle.standardError.write(Data("这台服务器还没配置好\n".utf8))
            exit(1)
        }
        let accounts = sync { () -> [Account] in
            do {
                let auth = try await AuthManager.currentAuth(serverID: srv.id)
                return try await APIClient(endpoint: srv.endpoint, auth: auth).fetchAccounts()
            } catch {
                FileHandle.standardError.write(Data(
                    "读取失败：\(SnapshotLoader.message(for: error, server: srv))\n".utf8))
                return []
            }
        }
        if accounts.isEmpty {
            print("没读到账号（检查地址和 API Key）")
            exit(1)
        }
        for a in accounts {
            print("\(srv.tracked(a.id) != nil ? "*" : " ") \(Fmt.padLeft("\(a.id)", 4))  \(Fmt.pad(a.displayName, 22)) \(a.subtitle)")
        }
    }
}
