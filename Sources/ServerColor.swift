import AppKit

/// 服务器颜色：配置里存名字（或 `#RRGGBB`），这里换成系统语义色，深浅色模式自动适配。
enum ServerColor {
    static let names: [String: String] = [
        "blue": "蓝", "green": "绿", "purple": "紫", "pink": "粉",
        "teal": "青", "indigo": "靛", "brown": "棕", "yellow": "黄",
    ]

    static func color(_ name: String) -> NSColor {
        switch name {
        case "blue": return .systemBlue
        case "green": return .systemGreen
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "teal": return .systemTeal
        case "indigo": return .systemIndigo
        case "brown": return .systemBrown
        case "yellow": return .systemYellow
        default: return hex(name) ?? .systemBlue
        }
    }

    private static func hex(_ s: String) -> NSColor? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// 菜单 / 设置窗口里用的小圆点
    static func dot(_ color: NSColor, diameter: CGFloat = 9) -> NSImage {
        let img = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}

extension TrackedAccount {
    var nsColor: NSColor { ServerColor.color(color) }
}
