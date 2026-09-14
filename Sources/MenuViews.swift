import AppKit

/// 菜单里的自定义视图统一自上而下排版
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 圆角进度条
final class BarView: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var fillColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let pct = max(0, min(1, progress))
        guard pct > 0 else { return }
        // 极小占比也要看得见，至少留一个圆点
        let w = max(bounds.width * CGFloat(pct), bounds.height)
        fillColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}

/// 菜单行。内容左边留 21pt 让开对勾栏，跟系统菜单项的文字对齐。
enum MenuViews {
    static let width: CGFloat = 300
    static let leading: CGFloat = 21
    static let trailing: CGFloat = 16
    static var contentWidth: CGFloat { width - leading - trailing }

    static func color(for utilization: Double) -> NSColor {
        switch utilization {
        case 90...: return .systemRed
        case 75..<90: return .systemOrange
        default: return .controlAccentColor
        }
    }

    private static func label(_ text: String, font: NSFont, color: NSColor,
                              align: NSTextAlignment = .left) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = font
        f.textColor = color
        f.alignment = align
        f.lineBreakMode = .byTruncatingTail
        f.cell?.usesSingleLineMode = true
        return f
    }

    /// 顶部账号信息：名称 + 平台 / 邮箱 / 分组
    static func accountHeader(_ account: Account?, subtitle fallback: String) -> NSView {
        let container = FlippedView()
        var y: CGFloat = 8

        let title = label(account?.displayName ?? "sub2api 配额",
                          font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        title.frame = NSRect(x: leading, y: y, width: contentWidth, height: 17)
        container.addSubview(title)
        y += 18

        var bits: [String] = []
        if let a = account {
            bits.append("\(a.platform)/\(a.type)")
            if let e = a.email, !e.isEmpty { bits.append(e) }
            bits.append(contentsOf: a.groups)
        } else if !fallback.isEmpty {
            bits.append(fallback)
        }
        if !bits.isEmpty {
            let sub = label(bits.joined(separator: " · "),
                            font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
            sub.frame = NSRect(x: leading, y: y, width: contentWidth, height: 14)
            container.addSubview(sub)
            y += 15
        }

        container.frame = NSRect(x: 0, y: 0, width: width, height: y + 6)
        return container
    }

    /// 一个用量窗口：名称 · 百分比 / 进度条 / 重置时间与花费
    static func usageRow(_ w: UsageWindow) -> NSView {
        let container = FlippedView()
        let accent = color(for: w.utilization)
        var y: CGFloat = 5

        let pct = label(Fmt.percent(w.utilization),
                        font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                        color: w.utilization >= 75 ? accent : .secondaryLabelColor,
                        align: .right)
        pct.sizeToFit()
        let pctWidth = max(pct.frame.width, 44)

        let name = label(w.label, font: .systemFont(ofSize: 13), color: .labelColor)
        name.frame = NSRect(x: leading, y: y, width: contentWidth - pctWidth - 8, height: 16)
        container.addSubview(name)

        pct.frame = NSRect(x: leading + contentWidth - pctWidth, y: y + 1, width: pctWidth, height: 15)
        container.addSubview(pct)
        y += 19

        let bar = BarView()
        bar.progress = w.utilization / 100
        bar.fillColor = accent
        bar.frame = NSRect(x: leading, y: y, width: contentWidth, height: 4)
        container.addSubview(bar)
        y += 8

        var detail: [String] = []
        if let sec = w.remainingSeconds, sec > 0 {
            detail.append("\(Fmt.durationCN(sec))后重置")
        } else if let r = w.resetsAt {
            detail.append("\(Fmt.shortDateTime.string(from: r)) 重置")
        }
        if let c = w.cost { detail.append(Fmt.money(c)) }
        if !detail.isEmpty {
            let d = label(detail.joined(separator: " · "),
                          font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
            d.frame = NSRect(x: leading, y: y, width: contentWidth, height: 14)
            container.addSubview(d)
            y += 15
        }

        container.frame = NSRect(x: 0, y: 0, width: width, height: y + 5)
        return container
    }

    /// 统计行：金额/主数值突出，明细次一级，右上角可挂一条来源说明
    static func statRow(primary: String, secondary: String, note: String? = nil) -> NSView {
        let container = FlippedView()
        var y: CGFloat = 4
        var noteWidth: CGFloat = 0

        if let note {
            let n = label(note, font: .systemFont(ofSize: 11), color: .tertiaryLabelColor, align: .right)
            n.sizeToFit()
            noteWidth = min(n.frame.width, contentWidth * 0.55)
            n.frame = NSRect(x: leading + contentWidth - noteWidth, y: y + 3, width: noteWidth, height: 14)
            container.addSubview(n)
            noteWidth += 8
        }

        let value = label(primary, font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                          color: .labelColor)
        value.frame = NSRect(x: leading, y: y, width: contentWidth - noteWidth, height: 17)
        container.addSubview(value)
        y += 18

        let sub = label(secondary, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        sub.frame = NSRect(x: leading, y: y, width: contentWidth, height: 14)
        container.addSubview(sub)
        y += 15

        container.frame = NSRect(x: 0, y: 0, width: width, height: y + 4)
        return container
    }

    /// 单行说明（占位 / 报错 / 页脚），文字长了会自动折行
    static func noteRow(_ text: String, color textColor: NSColor = .secondaryLabelColor,
                        size: CGFloat = 11, symbol: String? = nil) -> NSView {
        let container = FlippedView()
        var x = leading
        var w = contentWidth

        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let iv = NSImageView(image: img)
            iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size + 1, weight: .regular)
            iv.contentTintColor = textColor
            iv.frame = NSRect(x: leading, y: 5, width: 14, height: 14)
            container.addSubview(iv)
            x += 19
            w -= 19
        }

        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: size)
        f.textColor = textColor
        f.preferredMaxLayoutWidth = w
        let h = f.sizeThatFits(NSSize(width: w, height: .greatestFiniteMagnitude)).height
        f.frame = NSRect(x: x, y: 4, width: w, height: h)
        container.addSubview(f)

        container.frame = NSRect(x: 0, y: 0, width: width, height: max(h, 16) + 9)
        return container
    }
}
