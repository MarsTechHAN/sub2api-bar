import AppKit
import ServiceManagement

/// 开机自动启动，走系统的「登录项」（SMAppService）。
/// 开没开以系统为准，不往配置文件里记：用户在系统设置里关掉，这边也跟着变。
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 系统要求用户在「登录项」里手动允许
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// 返回失败原因，成功时为 nil
    @discardableResult
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("launch at login \(on) failed: \(error)")
            return error.localizedDescription
        }
        if on, needsApproval {
            // 被系统拦下来了，直接把对应的设置页打开给用户
            SMAppService.openSystemSettingsLoginItems()
            return "请在「系统设置 → 通用 → 登录项」里允许 Sub2API Quota"
        }
        return nil
    }
}
