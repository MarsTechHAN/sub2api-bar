import Foundation

/// 一次刷新要打的三个接口，集中在这里；菜单栏和命令行共用。
enum SnapshotLoader {

    struct Result {
        var accounts: [Account] = []
        var snapshot = Snapshot()
    }

    static func load(endpoint: String, apiKey: String, accountID: Int, cycleMode: CycleMode, force: Bool) async -> Result {
        var out = Result()
        let client = APIClient(endpoint: endpoint, apiKey: apiKey)

        do {
            out.accounts = try await client.fetchAccounts()
        } catch {
            out.snapshot.errorMessage = (error as? APIError)?.message ?? error.localizedDescription
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
        out.snapshot.usage = (try? await usage) ?? .empty
        out.snapshot.today = (try? await today) ?? UsageStats()

        // 周期起点要先知道 7d 窗口什么时候重置，所以这一步必须排在 usage 之后
        let (start, basis) = cycleStart(mode: cycleMode, usage: out.snapshot.usage)
        out.snapshot.cycle = try? await client.fetchCycleStats(accountID: account.id, start: start, basis: basis)
        out.snapshot.fetchedAt = Date()

        if out.snapshot.usage.windows.isEmpty && out.snapshot.usage.error == nil {
            out.snapshot.errorMessage = "该账号没有用量窗口数据"
        }
        return out
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
