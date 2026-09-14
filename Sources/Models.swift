import Foundation

// MARK: - 账号

struct Account: Identifiable, Hashable {
    let id: Int
    let name: String
    let platform: String      // anthropic / openai / gemini ...
    let type: String          // oauth / setup-token / apikey ...
    let status: String
    let email: String?
    let groups: [String]

    var displayName: String { name.isEmpty ? "#\(id)" : name }
    var subtitle: String {
        var parts = ["\(platform)/\(type)"]
        if let email, !email.isEmpty { parts.append(email) }
        return parts.joined(separator: " · ")
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int else { return nil }
        self.id = id
        self.name = json["name"] as? String ?? ""
        self.platform = json["platform"] as? String ?? "-"
        self.type = json["type"] as? String ?? "-"
        self.status = json["status"] as? String ?? "-"
        let extra = json["extra"] as? [String: Any]
        self.email = extra?["email_address"] as? String
        self.groups = (json["groups"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }
}

// MARK: - 用量窗口

struct UsageWindow {
    let key: String
    let utilization: Double        // 0-100
    let resetsAt: Date?
    let remainingSeconds: Int?
    let requests: Int?
    let tokens: Int?
    let cost: Double?

    /// 已知窗口的展示顺序；未知 key 排在最后。
    static let knownOrder: [String] = [
        "five_hour",
        "seven_day",
        "seven_day_opus",
        "seven_day_fable",
        "seven_day_sonnet",
        "gemini_shared_daily",
        "gemini_pro_daily",
        "gemini_flash_daily",
    ]

    static let labels: [String: String] = [
        "five_hour": "5h",
        "seven_day": "7d",
        "seven_day_opus": "7d Opus",
        "seven_day_fable": "7d Fable",
        "seven_day_sonnet": "7d Sonnet",
        "gemini_shared_daily": "1d",
        "gemini_pro_daily": "Pro 1d",
        "gemini_flash_daily": "Flash 1d",
    ]

    var label: String {
        UsageWindow.labels[key] ?? key.replacingOccurrences(of: "_", with: " ")
    }

    /// 菜单栏标题用的紧凑标签
    var shortLabel: String {
        switch key {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        case "seven_day_opus": return "7dO"
        case "seven_day_fable": return "7dF"
        case "seven_day_sonnet": return "7dS"
        default: return label
        }
    }

    init?(key: String, json: Any?) {
        guard let d = json as? [String: Any] else { return nil }
        // utilization 可能是 Int 也可能是 Double
        let u: Double
        if let v = d["utilization"] as? Double { u = v }
        else if let v = d["utilization"] as? Int { u = Double(v) }
        else if let v = d["used_percent"] as? Double { u = v }
        else if let v = d["used_percent"] as? Int { u = Double(v) }
        else { return nil }

        self.key = key
        self.utilization = u
        self.resetsAt = DateParse.date(from: d["resets_at"] ?? d["reset_at"])
        self.remainingSeconds = d["remaining_seconds"] as? Int
        let ws = d["window_stats"] as? [String: Any]
        self.requests = ws?["requests"] as? Int
        self.tokens = ws?["tokens"] as? Int
        if let c = ws?["cost"] as? Double { self.cost = c }
        else if let c = ws?["cost"] as? Int { self.cost = Double(c) }
        else { self.cost = nil }
    }
}

struct UsageSnapshot {
    let windows: [UsageWindow]
    let source: String?           // "passive" / nil(active)
    let sampledAt: Date?
    let error: String?

    static let empty = UsageSnapshot(windows: [], source: nil, sampledAt: nil, error: nil)

    init(windows: [UsageWindow], source: String?, sampledAt: Date?, error: String?) {
        self.windows = windows
        self.source = source
        self.sampledAt = sampledAt
        self.error = error
    }

    init(json: [String: Any]) {
        let reserved: Set<String> = ["source", "updated_at", "error", "plan", "balance", "models", "eligible", "configured"]
        var found: [UsageWindow] = []
        for (k, v) in json where !reserved.contains(k) {
            if let w = UsageWindow(key: k, json: v) { found.append(w) }
        }
        let order = UsageWindow.knownOrder
        found.sort { a, b in
            let ia = order.firstIndex(of: a.key) ?? order.count
            let ib = order.firstIndex(of: b.key) ?? order.count
            return ia == ib ? a.key < b.key : ia < ib
        }
        self.windows = found
        self.source = json["source"] as? String
        self.sampledAt = DateParse.date(from: json["updated_at"])
        self.error = json["error"] as? String
    }

    func window(key: String) -> UsageWindow? { windows.first { $0.key == key } }
    var hottest: UsageWindow? { windows.max { $0.utilization < $1.utilization } }
}

// MARK: - 用量统计

struct UsageStats {
    var requests: Int = 0
    var tokens: Int = 0
    var cost: Double = 0

    init() {}

    init(json: [String: Any]) {
        requests = json["requests"] as? Int ?? 0
        tokens = json["tokens"] as? Int ?? 0
        if let c = json["cost"] as? Double { cost = c }
        else if let c = json["cost"] as? Int { cost = Double(c) }
    }

    var line: String {
        "请求 \(Fmt.count(requests)) · tokens \(Fmt.tokens(tokens)) · \(Fmt.money(cost))"
    }
}

struct CycleStats {
    let start: Date
    let end: Date
    let stats: UsageStats
    /// 周期是怎么定出来的，直接说给用户听
    let basis: String
    /// 起点不在 00:00 时，日粒度的历史会把起点当天整天算进来，数字偏大
    let approximate: Bool

    var rangeLabel: String {
        let s = Fmt.shortDateTime.string(from: start)
        return "\(s) ~ 现在 · \(basis)"
    }

    var statsLine: String {
        (approximate ? "≈ " : "") + stats.line
    }
}

/// 一次完整刷新的结果
struct Snapshot {
    var account: Account?
    var usage: UsageSnapshot = .empty
    var today: UsageStats = UsageStats()
    var cycle: CycleStats?
    var fetchedAt: Date = Date()
    var errorMessage: String?
}
