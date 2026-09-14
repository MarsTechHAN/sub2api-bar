import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    // 顶层代码是 nonisolated 的，构造函数得跟着放开
    nonisolated override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusItemController()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// 带参数时只做配置/自检，不起界面
if CLI.run(Array(CommandLine.arguments.dropFirst())) { exit(0) }

let app = NSApplication.shared
// 只活在菜单栏，不占 Dock、不抢焦点
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
