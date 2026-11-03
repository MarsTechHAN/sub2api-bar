import Foundation

/// 一台服务器一次刷新要打的接口，集中在这里；菜单栏和命令行共用。
enum SnapshotLoader {

    struct Result {
        var accounts: [Account] = []
        /// 每个监控的账号一份，顺序和配置里一致
        var snapshots: [Snapshot] = []
        /// 整台服务器层面的失败（认证、账号列表），这时 snapshots 为空
        var errorMessage: String?
        /// 配置里没选账号、这次自动挑的那个
        var autoPicked: Int?
        /// 有接口返回 401，登录模式下可以换一次 token 再试
        var needsRefresh = false
        var fetchedAt = Date()
    }

    /// 拉一台服务器。登录模式下遇到 401 会自动刷新令牌并重试一次。
    static func load(serverID: String, force: Bool = false) async -> Result {
        guard let s = Settings.shared.server(serverID), !s.endpoint.isEmpty else {
            var out = Result()
            out.errorMessage = "未配置服务地址"
            return out
        }
        let ids = s.accounts.map(\.id)
        do {
            let auth = try await AuthManager.currentAuth(serverID: serverID)
            var out = await load(endpoint: s.endpoint, auth: auth, accountIDs: ids, force: force, server: s)
            if out.needsRefresh, s.authMode == .login {
                let fresh = try await AuthManager.refreshAfterUnauthorized(serverID: serverID)
                out = await load(endpoint: s.endpoint, auth: fresh, accountIDs: ids, force: force, server: s)
            }
            return out
        } catch {
            var out = Result()
            out.errorMessage = message(for: error, server: s)
            return out
        }
    }

    static func load(endpoint: String, auth: APIClient.Auth, accountIDs: [Int], force: Bool,
                     server: ServerConfig? = nil) async -> Result {
        var out = Result()
        let client = APIClient(endpoint: endpoint, auth: auth)

        do {
            out.accounts = try await client.fetchAccounts()
        } catch {
            if let e = error as? APIError, e.status == 401 { out.needsRefresh = true }
            out.errorMessage = message(for: error, context: "账号列表", server: server)
            return out
        }

        var ids = accountIDs
        if ids.isEmpty {
            // 还没选过账号：优先 anthropic，再退到第一个
            guard let pick = out.accounts.first(where: { $0.platform == "anthropic" }) ?? out.accounts.first else {
                out.errorMessage = "服务上没有任何账号"
                return out
            }
            out.autoPicked = pick.id
            ids = [pick.id]
        }

        // 各账号互不依赖，并发拿
        let accounts = out.accounts
        let results = await withTaskGroup(of: (Int, Snapshot, Bool).self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask {
                    let (snap, unauthorized) = await loadAccount(id, accounts: accounts, client: client,
                                                                 endpoint: endpoint, force: force, server: server)
                    return (i, snap, unauthorized)
                }
            }
            var collected: [(Int, Snapshot, Bool)] = []
            for await r in group { collected.append(r) }
            return collected.sorted { $0.0 < $1.0 }
        }
        out.snapshots = results.map(\.1)
        out.needsRefresh = results.contains { $0.2 }
        out.fetchedAt = Date()
        return out
    }

    /// 一个账号的用量窗口 / 今日 / 本周期。返回的 Bool 表示中途遇到过 401。
    private static func loadAccount(_ id: Int, accounts: [Account], client: APIClient, endpoint: String,
                                    force: Bool, server: ServerConfig?) async -> (Snapshot, Bool) {
        var snap = Snapshot()
        snap.accountID = id
        var unauthorized = false
        func note(_ error: Error) {
            if let e = error as? APIError, e.status == 401 { unauthorized = true }
        }

        guard let account = accounts.first(where: { $0.id == id }) else {
            snap.errorMessage = "账号 #\(id) 在服务上已不存在"
            return (snap, false)
        }
        snap.account = account

        async let usage = client.fetchUsage(accountID: id, force: force)
        async let today = client.fetchTodayStats(accountID: id)

        do {
            snap.usage = try await usage
        } catch {
            note(error)
            snap.usage = UsageSnapshot(windows: [], source: nil, sampledAt: nil,
                                       error: message(for: error, context: "用量", server: server))
        }
        do {
            snap.today = try await today
        } catch {
            note(error)
            snap.todayError = message(for: error, context: "今日用量", brief: true, server: server)
        }

        // 窗口起点要先知道 7d 窗口什么时候重置，所以这一步必须排在 usage 之后
        let (start, basis) = windowStart(usage: snap.usage)
        do {
            let stats = try await windowStats(client: client, cacheKey: "\(endpoint)#\(id)",
                                              accountID: id, start: start)
            snap.cycle = CycleStats(start: start, stats: stats, basis: basis)
        } catch {
            note(error)
            snap.cycleError = message(for: error, context: "本周期", brief: true, server: server)
        }
        snap.fetchedAt = Date()

        if snap.usage.windows.isEmpty && snap.usage.error == nil {
            snap.errorMessage = "该账号没有用量窗口数据"
        }
        return (snap, unauthorized)
    }

    /// 本周期固定是 7d 滚动窗口：重置时间往前 7 天就是起点。
    static func windowStart(usage: UsageSnapshot) -> (Date, String) {
        if let reset = usage.window(key: "seven_day")?.resetsAt {
            return (RollingWindow.start(fromSevenDayResetAt: reset), "7d 窗口")
        }
        return (RollingWindow.lastSevenDays(), "近 7 天")
    }

    /// `[start, now)` 的精确用量。统计接口只有整日粒度，所以拆成两段：
    /// 起点所在那天的零头逐条累加请求明细，之后的整日走汇总接口。
    /// 零头那段已经是过去的时间，结果不会再变，按起点缓存。
    static func windowStats(client: APIClient, cacheKey: String, accountID: Int,
                            start: Date, now: Date = Date()) async throws -> UsageStats {
        let cal = Calendar.current
        let firstDay = Fmt.isoDay.string(from: start)
        let nextMidnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: start)) ?? now
        let today = Fmt.isoDay.string(from: now)

        // 窗口还没跨过午夜：全在今天，直接逐条累加
        guard nextMidnight <= now else {
            return try await client.fetchLogStats(accountID: accountID, day: firstDay, since: start)
        }

        let key = "\(cacheKey)#\(Int(start.timeIntervalSince1970))"
        let head: UsageStats
        if let cached = HeadCache.shared.get(key) {
            head = cached
        } else if cal.startOfDay(for: start) == start {
            head = UsageStats()   // 起点正好是零点，没有零头
        } else {
            head = try await client.fetchLogStats(accountID: accountID, day: firstDay, since: start)
            HeadCache.shared.set(key, head)
        }
        let rest = try await client.fetchDayRangeStats(accountID: accountID,
                                                       fromDay: Fmt.isoDay.string(from: nextMidnight),
                                                       toDay: today)
        return head + rest
    }

    /// 窗口起点那天的零头用量。起点一周才变一次，条目很少。
    private final class HeadCache: @unchecked Sendable {
        static let shared = HeadCache()
        private let lock = NSLock()
        private var store: [String: UsageStats] = [:]

        func get(_ key: String) -> UsageStats? {
            lock.lock(); defer { lock.unlock() }
            return store[key]
        }

        func set(_ key: String, _ value: UsageStats) {
            lock.lock(); defer { lock.unlock() }
            if store.count > 64 { store.removeAll() }
            store[key] = value
        }
    }

    /// 把接口错误翻译成用户能照着处理的话。
    static func message(for error: Error, context: String? = nil, brief: Bool = false,
                        server: ServerConfig? = nil) -> String {
        let prefix = context.map { "\($0)：" } ?? ""
        guard let e = error as? APIError else {
            return prefix + error.localizedDescription
        }
        let isLogin = server?.authMode == .login
        let restricted = server.map { $0.authMode == .apiKey && $0.apiKey.hasPrefix("adm_sc_") } ?? false
        if e.status == 401 {
            switch e.code {
            case "INVALID_CREDENTIALS":
                return prefix + (e.message.isEmpty ? "邮箱或密码不正确" : e.message)
            case "REFRESH_TOKEN_INVALID", "REFRESH_TOKEN_EXPIRED", "TOKEN_EXPIRED",
                 "TOKEN_REVOKED", "USER_NOT_FOUND", "USER_INACTIVE":
                return prefix + "登录已过期，请重新登录"
            case "INVALID_ADMIN_KEY":
                return prefix + "API Key 无效、已撤销，或当前 IP 不在允许列表"
            default:
                return prefix + (isLogin ? "登录已失效，请到设置里重新登录" : "API Key 无效，请检查设置")
            }
        }
        if e.isForbidden {
            if restricted {
                return prefix + (brief ? "受限密钥无权限"
                    : "受限密钥（adm_sc_）读不到用量，请在设置里改用「管理员登录」或旧版全权 API Key")
            }
            return prefix + (brief || e.message.isEmpty ? "没有权限（HTTP 403）" : e.message)
        }
        return prefix + e.message
    }
}
