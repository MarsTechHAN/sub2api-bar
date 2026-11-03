import Foundation

/// 悬停提示 / 命令行 dump 共用的纯文本报告。
/// 悬停提示是系统画的气泡，画不了进度条，所以这里只讲事实，不摆 ASCII 图形。
enum Report {

    /// 多台服务器时传 serverName，第一行换成服务器名，账号挪到第二行。
    static func full(_ s: Snapshot, serverName: String? = nil) -> String {
        var lines: [String] = []

        if let serverName { lines.append("【\(serverName)】") }
        if let a = s.account {
            lines.append("\(a.displayName)  ·  \(a.subtitle)")
            if !a.groups.isEmpty { lines.append("分组：" + a.groups.joined(separator: "、")) }
        } else if serverName == nil {
            lines.append("sub2api 配额")
        }
        // 账号本身就没拿到（被删了、认证失败），后面各节都是空的，只说原因
        if s.account == nil, let e = s.errorMessage {
            lines.append("⚠️ \(e)")
            return lines.joined(separator: "\n")
        }
        lines.append("")

        lines.append("用量窗口")
        if s.usage.windows.isEmpty {
            lines.append("  暂无数据")
        }
        for w in s.usage.windows {
            var head = "  \(w.label)　已用 \(Fmt.percent(w.utilization))"
            if let sec = w.remainingSeconds, sec > 0 {
                head += "，\(Fmt.durationCN(sec))后重置"
            } else if let r = w.resetsAt {
                head += "，\(Fmt.shortDateTime.string(from: r)) 重置"
            }
            lines.append(head)
            if w.requests != nil || w.cost != nil {
                lines.append("    \(Fmt.count(w.requests)) 次请求 · \(Fmt.tokens(w.tokens)) tokens · \(Fmt.money(w.cost))")
            }
        }
        lines.append("")

        lines.append("今日")
        if let e = s.todayError {
            lines.append("  ⚠️ \(e)")
        } else {
            lines.append("  " + s.today.line)
        }
        lines.append("")

        if let c = s.cycle {
            lines.append("本周期（\(c.basis)，\(Fmt.shortDateTime.string(from: c.start)) 起）")
            lines.append("  " + c.stats.line)
        } else {
            lines.append("本周期")
            lines.append("  " + (s.cycleError.map { "⚠️ \($0)" } ?? "暂无数据"))
        }
        lines.append("")

        lines.append("更新于 \(Fmt.clock.string(from: s.fetchedAt))")
        if let e = s.usage.error { lines.append("⚠️ \(e)") }
        if let e = s.errorMessage { lines.append("⚠️ \(e)") }

        return lines.joined(separator: "\n")
    }
}
