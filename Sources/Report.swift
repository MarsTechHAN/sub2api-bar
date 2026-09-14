import Foundation

/// 悬停提示 / 命令行 dump 共用的纯文本报告。
/// 悬停提示是系统画的气泡，画不了进度条，所以这里只讲事实，不摆 ASCII 图形。
enum Report {

    static func full(_ s: Snapshot) -> String {
        var lines: [String] = []

        if let a = s.account {
            lines.append("\(a.displayName)  ·  \(a.subtitle)")
            if !a.groups.isEmpty { lines.append("分组：" + a.groups.joined(separator: "、")) }
        } else {
            lines.append("sub2api 配额")
        }
        lines.append("")

        lines.append("用量窗口")
        if s.usage.windows.isEmpty {
            lines.append("  暂无数据")
        }
        for w in s.usage.windows {
            lines.append("  \(w.label)　已用 \(Fmt.percent(w.utilization))")
            var detail: [String] = []
            if let sec = w.remainingSeconds, sec > 0 {
                detail.append("\(Fmt.durationCN(sec))后重置")
            }
            if let r = w.resetsAt { detail.append("重置于 \(Fmt.shortDateTime.string(from: r))") }
            if !detail.isEmpty { lines.append("    " + detail.joined(separator: "，")) }
            if w.requests != nil || w.cost != nil {
                lines.append("    窗口内 \(Fmt.count(w.requests)) 次请求 · \(Fmt.tokens(w.tokens)) tokens · \(Fmt.money(w.cost))")
            }
        }
        lines.append("")

        lines.append("今日用量")
        lines.append("  " + s.today.line)
        lines.append("")

        lines.append("计费周期")
        if let c = s.cycle {
            lines.append("  \(Fmt.shortDateTime.string(from: c.start)) 起至现在（\(c.basis)）")
            lines.append("  " + c.statsLine)
            if c.approximate {
                lines.append("  历史只有整日粒度，起点当天被整天计入，金额略偏大")
            }
        } else {
            lines.append("  暂无数据")
        }
        lines.append("")

        var footer: [String] = []
        if let src = s.usage.source { footer.append("数据源 \(src)") }
        if let t = s.usage.sampledAt { footer.append("采样 \(Fmt.shortDateTime.string(from: t))") }
        footer.append("更新于 \(Fmt.clock.string(from: s.fetchedAt))")
        lines.append(footer.joined(separator: " · "))

        if let e = s.usage.error { lines.append("⚠️ \(e)") }
        if let e = s.errorMessage { lines.append("⚠️ \(e)") }

        return lines.joined(separator: "\n")
    }
}
