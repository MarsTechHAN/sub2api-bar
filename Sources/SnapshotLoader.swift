import Foundation

/// 一次刷新要打的三个接口，集中在这里；菜单栏和命令行共用。
enum SnapshotLoader {

    struct Result {
        var accounts: [Account] = []
        var snapshot = Snapshot()
        /// 有接口返回 401，登录模式下可以换一次 token 再试
        var needsRefresh = false

        mutating func note(_ error: Error) {
            if let e = error as? APIError, e.status == 401 {
                needsRefresh = true
            }
        }
    }

    /// 用当前配置拉一次。登录模式下遇到 401 会自动刷新令牌并重试一次。
    static func loadConfigured(force: Bool = false) async -> Result {
        let s = Settings.shared
        guard !s.endpoint.isEmpty else {
            var out = Result()
            out.snapshot.errorMessage = "未配置服务地址"
            return out
        }
        do {
            let auth = try await AuthManager.currentAuth(endpoint: s.endpoint)
            var out = await load(endpoint: s.endpoint, auth: auth,
                                 accountID: s.accountID, cycleMode: s.cycleMode, force: force)
            if out.needsRefresh, s.authMode == .login {
                let fresh = try await AuthManager.refreshAfterUnauthorized(endpoint: s.endpoint)
                out = await load(endpoint: s.endpoint, auth: fresh,
                                 accountID: s.accountID, cycleMode: s.cycleMode, force: force)
            }
            return out
        } catch {
            var out = Result()
            out.snapshot.errorMessage = message(for: error)
            return out
        }
    }

    static func load(endpoint: String, auth: APIClient.Auth, accountID: Int, cycleMode: CycleMode, force: Bool) async -> Result {
        var out = Result()
        let client = APIClient(endpoint: endpoint, auth: auth)

        do {
            out.accounts = try await client.fetchAccounts()
        } catch {
            out.note(error)
            out.snapshot.errorMessage = message(for: error, context: "账号列表")
            return out
        }

        // 选中的账号不在了就回落：优先 anthropic，再退到第一个
        guard let account = out.accounts.first(where: { $0.id == accountID })
                ?? out.accounts.first(where: { $0.platform == "anthropic" })
                ?? out.accounts.first
        else {
            out.snapshot.errorMessage = "服务上没有任何账号"
            return out
        }
        out.snapshot.account = account

        // 用量和今日互不依赖，并发拿
        async let usage = client.fetchUsage(accountID: account.id, force: force)
        async let today = client.fetchTodayStats(accountID: account.id)

        do {
            out.snapshot.usage = try await usage
        } catch {
            out.note(error)
            out.snapshot.usage = UsageSnapshot(windows: [], source: nil, sampledAt: nil,
                                               error: message(for: error, context: "用量"))
        }
        do {
            out.snapshot.today = try await today
        } catch {
            out.note(error)
            out.snapshot.todayError = message(for: error, context: "今日用量", brief: true)
        }

        // 周期起点要先知道 7d 窗口什么时候重置，所以这一步必须排在 usage 之后
        let (start, basis) = cycleStart(mode: cycleMode, usage: out.snapshot.usage)
        do {
            out.snapshot.cycle = try await client.fetchCycleStats(accountID: account.id, start: start, basis: basis)
        } catch {
            out.note(error)
            out.snapshot.cycleError = message(for: error, context: "计费周期", brief: true)
        }
        out.snapshot.fetchedAt = Date()

        if out.snapshot.usage.windows.isEmpty && out.snapshot.usage.error == nil {
            out.snapshot.errorMessage = "该账号没有用量窗口数据"
        }
        return out
    }

    /// 把接口错误翻译成用户能照着处理的话。
    static func message(for error: Error, context: String? = nil, brief: Bool = false) -> String {
        let prefix = context.map { "\($0)：" } ?? ""
        guard let e = error as? APIError else {
            return prefix + error.localizedDescription
        }
        if e.status == 401 {
            switch e.code {
            case "INVALID_CREDENTIALS":
                return prefix + (e.message.isEmpty ? "邮箱或密码不正确" : e.message)
            case "REFRESH_TOKEN_INVALID", "REFRESH_TOKEN_EXPIRED", "TOKEN_EXPIRED",
                 "TOKEN_REVOKED", "USER_NOT_FOUND", "USER_INACTIVE":
                return prefix + "登录已过期，请重新登录"
            case "INVALID_ADMIN_KEY":
                return prefix + "管理 API Key 无效、已撤销，或当前 IP 不在允许列表"
            default:
                return prefix + (Settings.shared.authMode == .login
                    ? "登录已失效，请到设置里重新登录"
                    : "管理 API Key 无效，请检查设置")
            }
        }
        if e.isForbidden {
            let s = Settings.shared
            if brief {
                return prefix + (s.authMode == .apiKey && s.apiKey.hasPrefix("adm_sc_")
                    ? "当前受限密钥没有权限（HTTP 403）"
                    : "没有权限（HTTP 403）")
            }
            if s.authMode == .apiKey && s.apiKey.hasPrefix("adm_sc_") {
                return prefix + "受限管理密钥（adm_sc_）没有读取账号用量的权限。"
                    + "新版 sub2api 只把用量接口开放给旧版全权管理员 API Key 或管理员登录。"
                    + "请在设置里改用「管理员登录」（或换用旧版全权 API Key）。"
            }
            return prefix + (e.message.isEmpty ? "没有权限访问该接口 (HTTP 403)" : e.message)
        }
        return prefix + e.message
    }

    /// 返回周期起点和它的来历说明。
    static func cycleStart(mode: CycleMode, usage: UsageSnapshot) -> (Date, String) {
        switch mode {
        case .sevenDayWindow:
            // 7d 窗口是滚动的：重置时间往前 7 天就是本轮起点
            if let reset = usage.window(key: "seven_day")?.resetsAt {
                return (BillingCycle.start(fromSevenDayResetAt: reset), "7d 窗口")
            }
            // 账号没有 7d 窗口（比如 apikey 账号），退回最近 7 天
            let fallback = Calendar.current.startOfDay(for: Date().addingTimeInterval(-6 * 86400))
            return (fallback, "近 7 天（该账号无 7d 窗口）")
        case .monthly(let day):
            return (BillingCycle.start(anchorDay: day), "每月 \(day) 号")
        }
    }
}
