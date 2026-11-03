import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    /// 当前 timer 用的间隔，用来判断手改配置后要不要重启轮询
    private var timerInterval: TimeInterval?

    /// 每台服务器各自的数据和刷新状态，按服务器 id 存
    private struct ServerState {
        var accounts: [Account] = []
        /// 各监控账号的数据，按账号 id 存
        var snapshots: [Int: Snapshot] = [:]
        /// 认证失败、账号列表读不到这类整台服务器的问题
        var error: String?
        var fetchedAt: Date?
        var isRefreshing = false
        /// 刷新过程中又有新请求（切换账号、保存设置）时，等这次跑完再补一次
        var pending = false
        var pendingForce = false
    }
    private var states: [String: ServerState] = [:]
    private var settingsWC: SettingsWindowController?

    /// 菜单栏 / 菜单上的一项：某台服务器上的某个账号
    private struct Entry {
        let server: ServerConfig
        let tracked: TrackedAccount
        let snapshot: Snapshot
        let isRefreshing: Bool
        /// 账号名，数据还没回来时用缓存的账号列表兜底
        let accountName: String
        var color: NSColor { tracked.nsColor }
    }

    private var isRefreshing: Bool { states.values.contains { $0.isRefreshing } }

    private func state(_ id: String) -> ServerState { states[id] ?? ServerState() }

    /// 所有服务器上所有监控中的账号。没选过账号的服务器先占一个空位，显示“加载中”。
    private var entries: [Entry] {
        Settings.shared.configuredServers.flatMap { server -> [Entry] in
            let st = state(server.id)
            let tracked = server.accounts.isEmpty
                ? [TrackedAccount(id: 0, color: ServerConfig.palette[0])]
                : server.accounts
            return tracked.map { t in
                var snap = st.snapshots[t.id] ?? Snapshot()
                if let e = st.error { snap.errorMessage = e }
                let name = snap.account?.displayName
                    ?? st.accounts.first { $0.id == t.id }?.displayName
                    ?? (t.id == 0 ? server.displayName : "#\(t.id)")
                return Entry(server: server, tracked: t, snapshot: snap,
                             isRefreshing: st.isRefreshing, accountName: name)
            }
        }
    }

    /// 系统菜单栏字体原样使用。不要换成 monospacedDigitSystemFont：
    /// 等宽数字会把 "7d" 里的 7 撑到统一字宽，凭空多出 1.4pt，看着像 "7 d"。
    /// 数字位数变化带来的抖动改用固定宽度解决（fixedLength）。
    private static let titleFont: NSFont = .menuBarFont(ofSize: 0)

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.isVisible = true
        // 固定 autosaveName，让 macOS 记住用户把它拖到了哪
        statusItem.autosaveName = "Sub2APIQuotaStatusItem"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageHugsTitle = true
        renderTitle()
        rebuildMenu()
        logPlacement()

        if Settings.shared.isConfigured {
            refresh()
            startTimer()
        } else {
            // 没配置过，第一次启动直接把设置窗口推到用户面前
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings(nil)
            }
        }
    }

    /// 图标看不见时基本靠这条日志判断：是没创建，还是被挤到刘海后面/屏幕外。
    private func logPlacement() {
        Log.write("statusItem visible=\(statusItem.isVisible) length=\(statusItem.length)")
        let btnFrame = statusItem.button?.frame ?? .zero
        let winFrame = statusItem.button?.window?.frame ?? .zero
        Log.write("  button.frame=\(NSStringFromRect(btnFrame)) window.frame=\(NSStringFromRect(winFrame))")
        for (i, s) in NSScreen.screens.enumerated() {
            Log.write("  screen[\(i)] frame=\(NSStringFromRect(s.frame)) visible=\(NSStringFromRect(s.visibleFrame)) notch=\(s.safeAreaInsets.top)")
        }
    }

    // MARK: - 定时刷新

    private func startTimer() {
        timer?.invalidate()
        let interval = TimeInterval(Settings.shared.refreshInterval)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerInterval = interval
    }

    /// 配置文件是给人手改的，reload 之后轮询本身也要跟着生效：
    /// 包括从“未配置”变成“已配置”（启动时压根没起 timer）和手改刷新间隔。
    private func syncTimer() {
        guard Settings.shared.isConfigured else {
            timer?.invalidate()
            timer = nil
            timerInterval = nil
            return
        }
        let interval = TimeInterval(Settings.shared.refreshInterval)
        if timer == nil || timerInterval != interval {
            startTimer()
        }
    }

    func settingsChanged() {
        syncTimer()
        refresh()
    }

    // MARK: - 拉数据

    func refresh(force: Bool = false) {
        let servers = Settings.shared.configuredServers
        // 删掉的服务器不再留数据
        let ids = Set(servers.map(\.id))
        states = states.filter { ids.contains($0.key) }
        for server in servers { refresh(serverID: server.id, force: force) }
        renderTitle()
        rebuildMenu()
    }

    private func refresh(serverID: String, force: Bool) {
        var st = state(serverID)
        if st.isRefreshing {
            // 不要直接丢掉请求：账号切换 / 保存设置经常刚好撞上自动轮询
            st.pending = true
            st.pendingForce = st.pendingForce || force
            states[serverID] = st
            return
        }
        st.isRefreshing = true
        states[serverID] = st

        Task { [weak self] in
            let result = await SnapshotLoader.load(serverID: serverID, force: force)
            await MainActor.run { self?.apply(result, serverID: serverID) }
        }
    }

    private func apply(_ result: SnapshotLoader.Result, serverID: String) {
        // 请求在路上时服务器被删了
        guard var st = states[serverID], let server = Settings.shared.server(serverID) else { return }
        st.isRefreshing = false
        if !result.accounts.isEmpty { st.accounts = result.accounts }
        st.error = result.errorMessage
        // 整台服务器出错时不留旧数据，菜单栏直接显示出错，免得把过时的百分比当成现状
        st.snapshots = result.errorMessage != nil ? [:] : Dictionary(result.snapshots.map { ($0.accountID, $0) },
                                                                          uniquingKeysWith: { _, b in b })
        st.fetchedAt = result.fetchedAt
        if let e = result.errorMessage {
            Log.write("refresh error [\(server.displayName)]: \(e)")
        }
        for snap in result.snapshots {
            if let e = snap.errorMessage ?? snap.usage.error {
                Log.write("refresh error [\(server.displayName) #\(snap.accountID)]: \(e)")
            }
        }
        // 还没选过账号，把这次自动挑的记下来。请求发出之后用户可能已经自己选了，那就不动。
        if let picked = result.autoPicked, server.accounts.isEmpty {
            Settings.shared.setTracked(picked, true, serverID: serverID)
        }
        let pending = st.pending, force = st.pendingForce
        st.pending = false
        st.pendingForce = false
        states[serverID] = st
        renderTitle()
        rebuildMenu()

        if pending { refresh(serverID: serverID, force: force) }
    }

    // MARK: - 菜单栏

    /// 当前应该展示在菜单栏上的那一档
    private func primaryWindow(_ snapshot: Snapshot) -> UsageWindow? {
        switch Settings.shared.displayMode {
        case .auto: return snapshot.usage.hottest
        case .window(let key): return snapshot.usage.window(key: key) ?? snapshot.usage.hottest
        }
    }

    /// 菜单栏上出现哪几项：勾了“在菜单栏显示”的账号。全都没勾就全显示，免得图标空掉。
    private func barEntries(_ all: [Entry]) -> [Entry] {
        let shown = all.filter(\.tracked.showInBar)
        return shown.isEmpty ? all : shown
    }

    /// 用 title 而不是带 foregroundColor 的 attributedTitle：写死颜色的文字不会跟着
    /// 菜单栏失焦变浅、也不会在菜单展开时反色，而图标是模板图像会，两者就对不上了。
    /// 同理不设 contentTintColor —— 颜色全权交给 AppKit，任何状态下图文都一致。
    private func setTitle(_ text: String) {
        guard let button = statusItem.button else { return }
        button.font = StatusItemController.titleFont
        button.title = text
        button.contentTintColor = nil
    }

    private static func textWidth(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: titleFont]).width
    }

    /// 发丝空格，0.84pt。用它拼间距和补白，粒度够细，误差看不出来。
    private static let hairSpace = "\u{200A}"
    private static let hairWidth = max(textWidth(hairSpace), 0.1)

    private static func hairs(_ points: CGFloat) -> String {
        String(repeating: hairSpace, count: max(0, min(Int((points / hairWidth).rounded()), 64)))
    }

    /// 菜单栏标题。
    ///
    /// 宽度按两位数百分比钉死，0–99% 之间整项宽度和图标位置纹丝不动
    /// （只有罕见的 100% 会再宽一个字宽，不为它长期空着）。
    ///
    /// 一位数时富余出来的那个字宽总得放在某处：默认右对齐，放在标签和数字之间，
    /// 读起来像数字在按列对齐；放在最右边的话，它会顶在菜单项边缘，
    /// 看上去是和下一个菜单栏图标之间多了一道缝。改 title_align 可以换。
    private static func titleText(label: String?, utilization: Double) -> String {
        let value = Fmt.percent(utilization)
        let reserve = ["99%", "<1%"].map { textWidth($0) }.max() ?? 0
        let slack = hairs(reserve - textWidth(value))
        let alignRight = Settings.shared.titleAlignRight

        guard let label else { return alignRight ? slack + value : value + slack }
        let gap = hairs(Settings.shared.titleGap)
        return alignRight ? label + gap + slack + value
                          : label + gap + value + slack
    }

    private func renderTitle() {
        guard let button = statusItem.button else { return }
        let s = Settings.shared
        statusItem.length = NSStatusItem.variableLength

        guard s.isConfigured else {
            button.image = GaugeIcon.symbol("gearshape", description: "配置 sub2api 配额")
            setTitle("")
            button.toolTip = "点击配置 sub2api 服务器"
            return
        }
        let all = entries
        button.toolTip = tooltipText(all)
        if all.count > 1 {
            renderMultiTitle(button, barEntries(all))
            return
        }

        let snapshot = all.first?.snapshot ?? Snapshot()
        guard let w = primaryWindow(snapshot) else {
            let failed = snapshot.errorMessage != nil || snapshot.usage.error != nil
            button.image = failed
                ? GaugeIcon.symbol("exclamationmark.triangle", description: "读取失败")
                : GaugeIcon.ring(progress: 0)
            setTitle(failed ? "" : "…")
            return
        }

        button.image = s.showGauge ? GaugeIcon.ring(progress: w.utilization / 100) : nil
        let label: String? = s.showLabel ? w.shortLabel : nil
        let text = StatusItemController.titleText(label: label, utilization: w.utilization)

        setTitle(text)
        button.setAccessibilityTitle("\(w.label) 已用 \(Fmt.percent(w.utilization))")
        Log.write("title=\"\(label ?? "")|\(Fmt.percent(w.utilization))\" frameW=\(button.frame.width)")
    }

    /// 多个账号：每个一个彩色圆环 + 百分比，颜色就是账号的颜色。
    /// 彩色图像不再是模板图像，文字因此也改用 attributedTitle，颜色交给 labelColor
    /// 按菜单栏的外观去解析，深浅色下都看得清。
    private func renderMultiTitle(_ button: NSStatusBarButton, _ shown: [Entry]) {
        let s = Settings.shared
        let font = StatusItemController.titleFont
        let title = NSMutableAttributedString()
        var spoken: [String] = []

        for (i, entry) in shown.enumerated() {
            if i > 0 {
                title.append(NSAttributedString(string: StatusItemController.hairs(9),
                                                attributes: [.font: font]))
            }
            let color = entry.color
            let snapshot = entry.snapshot
            let icon: NSImage?
            var text = ""
            if let w = primaryWindow(snapshot) {
                icon = s.showGauge ? GaugeIcon.ring(progress: w.utilization / 100, color: color) : nil
                text = StatusItemController.titleText(label: s.showLabel ? w.shortLabel : nil,
                                                      utilization: w.utilization)
                spoken.append("\(entry.accountName) \(w.label) 已用 \(Fmt.percent(w.utilization))")
            } else if snapshot.errorMessage != nil || snapshot.usage.error != nil {
                icon = GaugeIcon.symbol("exclamationmark.triangle", description: "读取失败", color: color)
                spoken.append("\(entry.accountName) 读取失败")
            } else {
                icon = GaugeIcon.ring(progress: 0, color: color)
                text = "…"
            }

            if let icon {
                let attachment = NSTextAttachment()
                attachment.image = icon
                let size = icon.size
                attachment.bounds = NSRect(x: 0, y: (font.capHeight - size.height) / 2,
                                           width: size.width, height: size.height)
                title.append(NSAttributedString(attachment: attachment))
                if !text.isEmpty { text = StatusItemController.hairs(4) + text }
            }
            // 不画圆环时颜色只能落在文字上
            title.append(NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: icon == nil ? color : NSColor.labelColor,
            ]))
        }

        button.image = nil
        button.attributedTitle = title
        button.setAccessibilityTitle(spoken.joined(separator: "；"))
    }

    /// 悬停提示：把所有信息一次给全
    private func tooltipText(_ all: [Entry]) -> String {
        guard all.count > 1 else { return Report.full(all.first?.snapshot ?? Snapshot()) }
        let multiServer = Set(all.map(\.server.id)).count > 1
        return all
            .map { Report.full($0.snapshot, serverName: multiServer ? $0.server.displayName : nil) }
            .joined(separator: "\n\n")
    }

    // MARK: - 菜单

    func menuWillOpen(_ menu: NSMenu) {
        // 配置文件是给人手改的，改完点一下菜单栏就生效，不用退出重开
        Settings.shared.reload()
        syncTimer()
        renderTitle()
        rebuildMenu()
        // 打开菜单时顺手拉一次，保证看到的是当下的数。
        // 正在刷新时也排一次队：那次请求可能是在手改配置之前发出的，不能拿它当准。
        for server in Settings.shared.configuredServers {
            let st = state(server.id)
            let stale = st.fetchedAt.map { Date().timeIntervalSince($0) > 10 } ?? true
            if st.isRefreshing || stale {
                refresh(serverID: server.id, force: false)
            }
        }
    }

    private func addView(_ view: NSView) {
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addSection(_ title: String) {
        menu.addItem(.sectionHeader(title: title))
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let servers = Settings.shared.configuredServers

        guard !servers.isEmpty else {
            addView(MenuViews.header(title: "sub2api 配额", subtitle: "尚未配置服务器"))
            menu.addItem(.separator())
            addAction("设置…", #selector(openSettings(_:)), key: ",")
            addAction("退出", #selector(quit(_:)), key: "q")
            return
        }

        let all = entries
        if all.count == 1, let only = all.first {
            addFullBlock(only)
        } else {
            // 多台服务器时按服务器分节；同一台上的多个账号挨在一起
            let multiServer = servers.count > 1
            var lastServer: String?
            for entry in all {
                if entry.server.id != lastServer {
                    if lastServer != nil { menu.addItem(.separator()) }
                    if multiServer { addSection(entry.server.displayName) }
                    lastServer = entry.server.id
                }
                addCompactBlock(entry)
            }
        }

        // 设置
        menu.addItem(.separator())
        menu.addItem(accountSubmenu(servers))
        menu.addItem(displaySubmenu(all))
        menu.addItem(intervalSubmenu())
        let login = addAction("登录时启动", #selector(toggleLaunchAtLogin(_:)), key: "")
        login.state = LaunchAtLogin.isEnabled ? .on : (LaunchAtLogin.needsApproval ? .mixed : .off)

        menu.addItem(.separator())
        addAction(isRefreshing ? "刷新中…" : "立即刷新", #selector(refreshNow(_:)), key: "r", enabled: !isRefreshing)
        addAction("强制刷新（探测上游）", #selector(forceRefresh(_:)), key: "R", enabled: !isRefreshing)
        addAction("设置…", #selector(openSettings(_:)), key: ",")

        menu.addItem(.separator())
        if let latest = servers.compactMap({ states[$0.id]?.fetchedAt }).max() {
            addView(MenuViews.noteRow("更新于 " + Fmt.clock.string(from: latest), color: .tertiaryLabelColor))
        }
        addAction("退出", #selector(quit(_:)), key: "q")
    }

    private func addWarning(_ text: String) {
        addView(MenuViews.noteRow(text, color: .systemOrange, size: 11,
                                  symbol: "exclamationmark.triangle.fill"))
    }

    private func addUsageRows(_ entry: Entry, base: NSColor) {
        let snapshot = entry.snapshot
        if snapshot.usage.windows.isEmpty {
            if let e = snapshot.usage.error {
                addWarning(e)
            } else if snapshot.errorMessage == nil {
                addView(MenuViews.noteRow(entry.isRefreshing ? "加载中…" : "暂无数据"))
            }
        }
        for w in snapshot.usage.windows {
            addView(MenuViews.usageRow(w, base: base))
        }
    }

    /// 只监控一个账号：分节完整展示
    private func addFullBlock(_ entry: Entry) {
        let snapshot = entry.snapshot

        var bits: [String] = []
        if let a = snapshot.account {
            bits.append("\(a.platform)/\(a.type)")
            if let e = a.email, !e.isEmpty { bits.append(e) }
            bits.append(contentsOf: a.groups)
        } else {
            bits.append(entry.isRefreshing ? "加载中…" : entry.server.displayName)
        }
        addView(MenuViews.header(title: entry.accountName, subtitle: bits.joined(separator: " · ")))

        addSection("用量窗口")
        addUsageRows(entry, base: .controlAccentColor)

        addSection("今日")
        if let e = snapshot.todayError {
            addWarning(e)
        } else {
            addView(MenuViews.statRow(primary: Fmt.money(snapshot.today.cost),
                                      secondary: "\(Fmt.count(snapshot.today.requests)) 次请求 · \(Fmt.tokens(snapshot.today.tokens)) tokens"))
        }

        addSection("本周期")
        if let c = snapshot.cycle {
            addView(MenuViews.statRow(
                primary: Fmt.money(c.stats.cost),
                secondary: "\(Fmt.shortDateTime.string(from: c.start)) 起 · \(Fmt.count(c.stats.requests)) 次请求 · \(Fmt.tokens(c.stats.tokens)) tokens",
                note: c.basis))
        } else if let e = snapshot.cycleError {
            addWarning(e)
        } else {
            addView(MenuViews.noteRow(entry.isRefreshing ? "加载中…" : "暂无数据"))
        }

        if let e = snapshot.errorMessage {
            addWarning(e)
        }
    }

    /// 多个账号：每个一块，抬头带颜色圆点，今日 / 本周期并排一行
    private func addCompactBlock(_ entry: Entry) {
        let snapshot = entry.snapshot

        var bits: [String] = []
        if let a = snapshot.account {
            bits.append("\(a.platform)/\(a.type)")
            if let e = a.email, !e.isEmpty, e != a.displayName { bits.append(e) }
        } else if entry.isRefreshing {
            bits.append("加载中…")
        }
        addView(MenuViews.header(title: entry.accountName, subtitle: bits.joined(separator: " · "),
                                 color: entry.color))
        addUsageRows(entry, base: entry.color)

        if snapshot.account != nil {
            let cycleTitle = snapshot.cycle.map {
                "本周期 · \($0.basis)，\(Fmt.shortDateTime.string(from: $0.start)) 起"
            } ?? "本周期"
            addView(MenuViews.pairRow(
                ("今日", snapshot.todayError == nil ? Fmt.money(snapshot.today.cost) : "—"),
                (cycleTitle, snapshot.cycle.map { Fmt.money($0.stats.cost) } ?? "—")))
            for e in [snapshot.todayError, snapshot.cycleError].compactMap({ $0 }) {
                addWarning(e)
            }
        }
        if let e = snapshot.errorMessage {
            addWarning(e)
        }
    }

    @discardableResult
    private func addAction(_ title: String, _ sel: Selector, key: String, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        if key == key.uppercased() && !key.isEmpty && key.rangeOfCharacter(from: .letters) != nil {
            item.keyEquivalentModifierMask = [.command, .shift]
        }
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    /// 勾选要监控的账号，可以多选
    private func accountSubmenu(_ servers: [ServerConfig]) -> NSMenuItem {
        let root = NSMenuItem(title: "监控账号", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let multi = servers.count > 1

        for server in servers {
            let accounts = state(server.id).accounts
            if multi { sub.addItem(.sectionHeader(title: server.displayName)) }
            if accounts.isEmpty {
                let item = NSMenuItem(title: "加载中…", action: nil, keyEquivalent: "")
                item.isEnabled = false
                sub.addItem(item)
            }
            // 单台服务器时按平台分组，账号一多就不至于糊成一片；多台时平台挪进副标题
            let grouped = multi
                ? [("", accounts)]
                : Dictionary(grouping: accounts, by: \.platform).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            for (platform, list) in grouped {
                if !multi, grouped.count > 1 { sub.addItem(.sectionHeader(title: platform)) }
                for a in list {
                    let title = a.status == "active" ? a.displayName : "\(a.displayName)（\(a.status)）"
                    let item = NSMenuItem(title: title, action: #selector(toggleAccount(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = [server.id, a.id] as NSArray
                    let tracked = server.tracked(a.id)
                    item.state = tracked != nil ? .on : .off
                    if let tracked { item.image = ServerColor.dot(tracked.nsColor) }
                    let detail = multi
                        ? [a.platform, a.email ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                        : (a.email ?? "")
                    if !detail.isEmpty {
                        item.attributedTitle = subtitled(title, detail)
                    }
                    sub.addItem(item)
                }
            }
        }
        root.submenu = sub
        return root
    }

    /// 主标题 + 次一级副标题的两行菜单项，系统自带 App 里常见的写法
    private func subtitled(_ title: String, _ subtitle: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
        ])
        s.append(NSAttributedString(string: "\n" + subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return s
    }

    private func displaySubmenu(_ all: [Entry]) -> NSMenuItem {
        let root = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let mode = Settings.shared.displayMode

        let auto = NSMenuItem(title: "自动（占用最高的窗口）", action: #selector(pickDisplay(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = "auto"
        auto.state = mode == .auto ? .on : .off
        sub.addItem(auto)

        // 各账号返回了哪些窗口就列哪些；再补上常见但本次没返回的档位，便于提前锁定
        let windows = all.flatMap(\.snapshot.usage.windows)
        var keys: [String] = []
        for w in windows where !keys.contains(w.key) { keys.append(w.key) }
        for k in ["five_hour", "seven_day", "seven_day_opus", "seven_day_fable", "seven_day_sonnet"] where !keys.contains(k) {
            keys.append(k)
        }
        sub.addItem(.sectionHeader(title: "固定显示"))
        for k in keys {
            let label = UsageWindow.labels[k] ?? k
            let available = windows.contains { $0.key == k }
            let item = NSMenuItem(title: available ? label : "\(label)（无数据）",
                                  action: #selector(pickDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = k
            item.state = mode == .window(k) ? .on : .off
            sub.addItem(item)
        }

        sub.addItem(.sectionHeader(title: "样式"))
        let gauge = NSMenuItem(title: "显示环形进度", action: #selector(toggleGauge(_:)), keyEquivalent: "")
        gauge.target = self
        gauge.state = Settings.shared.showGauge ? .on : .off
        sub.addItem(gauge)
        let label = NSMenuItem(title: "显示窗口名", action: #selector(toggleLabel(_:)), keyEquivalent: "")
        label.target = self
        label.state = Settings.shared.showLabel ? .on : .off
        sub.addItem(label)

        // 多个账号时：每个账号能单独决定上不上菜单栏、用什么颜色
        if all.count > 1 {
            sub.addItem(.sectionHeader(title: "账号"))
            let multiServer = Set(all.map(\.server.id)).count > 1
            for entry in all where entry.tracked.id != 0 {
                let title = multiServer ? "\(entry.accountName)（\(entry.server.displayName)）" : entry.accountName
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = ServerColor.dot(entry.color)
                item.state = entry.tracked.showInBar ? .on : .off
                item.submenu = entryOptionsMenu(entry)
                sub.addItem(item)
            }
        }

        root.submenu = sub
        return root
    }

    private func entryOptionsMenu(_ entry: Entry) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let key = [entry.server.id, entry.tracked.id] as NSArray

        let show = NSMenuItem(title: "在菜单栏显示", action: #selector(toggleEntryInBar(_:)), keyEquivalent: "")
        show.target = self
        show.representedObject = key
        show.state = entry.tracked.showInBar ? .on : .off
        menu.addItem(show)

        menu.addItem(.sectionHeader(title: "颜色"))
        for name in ServerConfig.palette {
            let item = NSMenuItem(title: ServerColor.names[name] ?? name, action: #selector(pickEntryColor(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = [entry.server.id, entry.tracked.id, name] as NSArray
            item.image = ServerColor.dot(ServerColor.color(name))
            item.state = entry.tracked.color == name ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func intervalSubmenu() -> NSMenuItem {
        let root = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for (secs, title) in [(30, "30 秒"), (60, "1 分钟"), (300, "5 分钟"), (900, "15 分钟")] {
            let item = NSMenuItem(title: title, action: #selector(pickInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = secs
            item.state = Settings.shared.refreshInterval == secs ? .on : .off
            sub.addItem(item)
        }
        root.submenu = sub
        return root
    }

    // MARK: - 菜单动作

    @objc private func toggleAccount(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? NSArray, pair.count == 2,
              let serverID = pair[0] as? String, let accountID = pair[1] as? Int,
              let server = Settings.shared.server(serverID) else { return }
        Settings.shared.setTracked(accountID, server.tracked(accountID) == nil, serverID: serverID)
        refresh(serverID: serverID, force: false)
        renderTitle()
        rebuildMenu()
    }

    @objc private func toggleEntryInBar(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? NSArray, pair.count == 2,
              let serverID = pair[0] as? String, let accountID = pair[1] as? Int else { return }
        Settings.shared.updateTracked(accountID, serverID: serverID) { $0.showInBar.toggle() }
        renderTitle()
    }

    @objc private func pickEntryColor(_ sender: NSMenuItem) {
        guard let triple = sender.representedObject as? NSArray, triple.count == 3,
              let serverID = triple[0] as? String, let accountID = triple[1] as? Int,
              let color = triple[2] as? String else { return }
        Settings.shared.updateTracked(accountID, serverID: serverID) { $0.color = color }
        renderTitle()
        rebuildMenu()
    }

    @objc private func pickDisplay(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? String ?? "auto"
        Settings.shared.displayMode = DisplayMode(rawValue: raw)
        renderTitle()
    }

    @objc private func toggleGauge(_ sender: NSMenuItem) {
        Settings.shared.showGauge.toggle()
        renderTitle()
    }

    @objc private func toggleLabel(_ sender: NSMenuItem) {
        Settings.shared.showLabel.toggle()
        renderTitle()
    }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        Settings.shared.refreshInterval = sender.tag
        startTimer()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if let e = LaunchAtLogin.set(!LaunchAtLogin.isEnabled) {
            let alert = NSAlert()
            alert.messageText = "没能设置登录时启动"
            alert.informativeText = e
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func refreshNow(_ sender: Any?) { refresh() }

    @objc private func forceRefresh(_ sender: Any?) { refresh(force: true) }

    @objc private func openSettings(_ sender: Any?) {
        if settingsWC == nil {
            settingsWC = SettingsWindowController { [weak self] in self?.settingsChanged() }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
