import Foundation

// MARK: - 日期解析 / 格式化

enum DateParse {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// sub2api 返回的时间戳有三种形态：带小数秒的 RFC3339、不带小数秒的 RFC3339、Unix 秒。
    static func date(from any: Any?) -> Date? {
        if let s = any as? String, !s.isEmpty {
            return withFraction.date(from: s) ?? plain.date(from: s)
        }
        if let n = any as? Double, n > 0 { return Date(timeIntervalSince1970: n) }
        if let n = any as? Int, n > 0 { return Date(timeIntervalSince1970: Double(n)) }
        return nil
    }
}

enum Fmt {
    static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()

    /// 1234567 -> "1.23M"
    static func tokens(_ v: Int?) -> String {
        guard let v else { return "-" }
        let d = Double(v)
        switch abs(d) {
        case 1_000_000_000...: return String(format: "%.2fB", d / 1_000_000_000)
        case 1_000_000...: return String(format: "%.2fM", d / 1_000_000)
        case 1_000...: return String(format: "%.1fK", d / 1_000)
        default: return "\(v)"
        }
    }

    static func money(_ v: Double?) -> String {
        guard let v else { return "-" }
        if v >= 1000 {
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            nf.maximumFractionDigits = 2
            nf.minimumFractionDigits = 2
            return "$" + (nf.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v))
        }
        return String(format: "$%.2f", v)
    }

    static func count(_ v: Int?) -> String {
        guard let v else { return "-" }
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        return nf.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// 一律整百分比。用过但不足 1% 的显示成 "<1%"，免得四舍五入成 "0%" 被当成没数据。
    static func percent(_ v: Double) -> String {
        if v > 0, v < 1 { return "<1%" }
        return String(format: "%.0f%%", v)
    }

    /// 剩余时长：6d10h / 4h12m / 37m / 45s
    static func duration(_ seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "-" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d\(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    /// 界面上给人读的时长：6 天 9 小时 / 4 小时 12 分 / 37 分钟 / 45 秒
    static func durationCN(_ seconds: Int?) -> String {
        guard let s = seconds, s > 0 else { return "-" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d) 天 \(h) 小时" : "\(d) 天" }
        if h > 0 { return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时" }
        if m > 0 { return "\(m) 分钟" }
        return "\(s) 秒"
    }

    /// 方块进度条，只在终端输出里用。只要用过就至少点亮一格，否则低占用时整条全空，看着像没数据。
    static func gauge(_ utilization: Double, segments: Int = 10) -> String {
        let pct = max(0, min(100, utilization))
        var filled = Int((pct / 100 * Double(segments)).rounded())
        if pct > 0 { filled = max(1, filled) }
        if pct < 100 { filled = min(segments - 1, filled) }
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: segments - filled)
    }

    /// 左对齐补齐到固定宽度（等宽字体下用于菜单对齐）
    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    static func padLeft(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }
}

// MARK: - 计费周期

enum BillingCycle {
    /// 7d 窗口的起点 = 重置时间往前推 7 天。Claude / Codex 的额度都是这个滚动窗口。
    static func start(fromSevenDayResetAt resetsAt: Date) -> Date {
        resetsAt.addingTimeInterval(-7 * 86400)
    }

    /// 按“每月 anchorDay 号”切分周期，返回当前周期的起始日（当天 00:00）。
    static func start(anchorDay: Int, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let anchor = max(1, min(28, anchorDay))
        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        let today = comps.day ?? 1
        if today < anchor {
            // 还没到本月账单日，周期从上个月的账单日开始
            let firstOfThisMonth = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? now
            let prev = calendar.date(byAdding: .month, value: -1, to: firstOfThisMonth) ?? now
            comps = calendar.dateComponents([.year, .month], from: prev)
        }
        comps.day = anchor
        comps.hour = 0; comps.minute = 0; comps.second = 0
        return calendar.startOfDay(for: calendar.date(from: comps) ?? now)
    }

    /// 从周期起点到今天共几个自然日（含今天），用于决定向接口请求多少天的历史。
    static func daysElapsed(since start: Date, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: start),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        return max(1, min(400, days + 1))
    }
}
