import AppKit

/// 菜单栏图标。按 HIG 画成模板图像（只保留 alpha，颜色交给系统），
/// 这样浅色/深色、菜单栏染色、点开时的高亮态都会自动适配。
enum GaugeIcon {

    /// 环形进度。12 点方向起顺时针。
    static func ring(progress: Double, diameter: CGFloat = 14) -> NSImage {
        let pct = max(0, min(1, progress))
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let lineWidth: CGFloat = 1.8
            let radius = (min(rect.width, rect.height) - lineWidth) / 2
            let center = NSPoint(x: rect.midX, y: rect.midY)

            // 底环：同一个模板色压低透明度，染色后仍然协调
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            guard pct > 0 else { return true }

            // 用过就得看得见，给一个最小可见弧长
            let sweep = max(10, 360 * CGFloat(pct))
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "已用 \(Int((pct * 100).rounded()))%"
        return image
    }

    /// SF Symbol，取不到就退回空环
    static func symbol(_ name: String, description: String) -> NSImage {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: description) else {
            return ring(progress: 0)
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let sized = img.withSymbolConfiguration(config) ?? img
        sized.isTemplate = true
        return sized
    }
}
