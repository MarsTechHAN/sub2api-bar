import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?

    private var accounts: [Account] = []
    private var snapshot = Snapshot()
    private var isRefreshing = false
    private var settingsWC: SettingsWindowController?

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
    }

    func settingsChanged() {
        startTimer()
        refresh()
    }

    // MARK: - 拉数据

    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        let s = Settings.shared
        guard s.isConfigured else {
            snapshot = Snapshot()
            snapshot.errorMessage = "未配置服务地址或 API Key"
            renderTitle(); rebuildMenu()
            return
        }
        isRefreshing = true
        rebuildMenu()

        let endpoint = s.endpoint, apiKey = s.apiKey
        let accountID = s.accountID, cycleMode = s.cycleMode

        Task { [weak self] in
            let result = await SnapshotLoader.load(endpoint: endpoint, apiKey: apiKey,
                                                   accountID: accountID, cycleMode: cycleMode, force: force)
            await MainActor.run { self?.apply(result) }
        }
    }

    private func apply(_ result: SnapshotLoader.Result) {
        isRefreshing = false
        if !result.accounts.isEmpty { accounts = result.accounts }
        snapshot = result.snapshot
        // 之前选的账号没了，把回落的结果记下来
        if let a = result.snapshot.account, a.id != Settings.shared.accountID {
            Settings.shared.accountID = a.id
        }
        renderTitle()
        rebuildMenu()
    }

    // MARK: - 菜单栏

    /// 当前应该展示在菜单栏上的那一档
    private var primaryWindow: UsageWindow? {
        switch Settings.shared.displayMode {
        case .auto: return snapshot.usage.hottest
        case .window(let key): return snapshot.usage.window(key: key) ?? snapshot.usage.hottest
        }
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

        guard s.isConfigured else {
            statusItem.length = NSStatusItem.variableLength
            button.image = GaugeIcon.symbol("gearshape", description: "配置 sub2api 配额")
            setTitle("")
            button.toolTip = "点击配置 sub2api 服务地址与管理 API Key"
            return
        }

        guard let w = primaryWindow else {
            statusItem.length = NSStatusItem.variableLength
            let failed = snapshot.errorMessage != nil || snapshot.usage.error != nil
            button.image = failed
                ? GaugeIcon.symbol("exclamationmark.triangle", description: "读取失败")
                : GaugeIcon.ring(progress: 0)
            setTitle(failed ? "" : "…")
            button.toolTip = tooltipText()
            return
        }

        statusItem.length = NSStatusItem.variableLength
        button.image = s.showGauge ? GaugeIcon.ring(progress: w.utilization / 100) : nil
        let label: String? = s.showLabel ? w.shortLabel : nil
        let text = StatusItemController.titleText(label: label, utilization: w.utilization)

        setTitle(text)
        button.setAccessibilityTitle("\(w.label) 已用 \(Fmt.percent(w.utilization))")
        button.toolTip = tooltipText()
        Log.write("title=\"\(label ?? "")|\(Fmt.percent(w.utilization))\" frameW=\(button.frame.width)")
    }

    /// 悬停提示：把所有信息一次给全
    private func tooltipText() -> String {
        Report.full(snapshot)
    }

    // MARK: - 菜单

    func menuWillOpen(_ menu: NSMenu) {
        // 配置文件是给人手改的，改完点一下菜单栏就生效，不用退出重开
        Settings.shared.reload()
        renderTitle()
        rebuildMenu()
        // 打开菜单时顺手拉一次，保证看到的是当下的数
        if Settings.shared.isConfigured, Date().timeIntervalSince(snapshot.fetchedAt) > 10 { refresh() }
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
        let s = Settings.shared

        guard s.isConfigured else {
            addView(MenuViews.accountHeader(nil, subtitle: "尚未配置服务地址与 API Key"))
            menu.addItem(.separator())
            addAction("设置…", #selector(openSettings(_:)), key: ",")
            addAction("退出", #selector(quit(_:)), key: "q")
            return
        }

        addView(MenuViews.accountHeader(snapshot.account,
                                        subtitle: isRefreshing ? "加载中…" : "未选择账号"))

        // 用量窗口
        addSection("用量窗口")
        if snapshot.usage.windows.isEmpty {
            addView(MenuViews.noteRow(isRefreshing ? "加载中…" : "暂无数据"))
        }
        for w in snapshot.usage.windows {
            addView(MenuViews.usageRow(w))
        }

        // 今日
        addSection("今日用量")
        addView(MenuViews.statRow(primary: Fmt.money(snapshot.today.cost),
                                  secondary: "\(Fmt.count(snapshot.today.requests)) 次请求 · \(Fmt.tokens(snapshot.today.tokens)) tokens",
                                  note: Fmt.monthDay.string(from: snapshot.fetchedAt)))

        // 计费周期
        addSection("计费周期")
        if let c = snapshot.cycle {
            addView(MenuViews.statRow(
                primary: (c.approximate ? "≈ " : "") + Fmt.money(c.stats.cost),
                secondary: "\(Fmt.shortDateTime.string(from: c.start)) 起 · \(Fmt.count(c.stats.requests)) 次请求 · \(Fmt.tokens(c.stats.tokens)) tokens",
                note: c.basis))
            if c.approximate {
                addView(MenuViews.noteRow("历史数据只有整日粒度，周期起点当天被整天计入，金额略偏大。",
                                          color: .tertiaryLabelColor))
            }
        } else {
            addView(MenuViews.noteRow(isRefreshing ? "加载中…" : "暂无数据"))
        }

        if let e = snapshot.usage.error ?? snapshot.errorMessage {
            menu.addItem(.separator())
            addView(MenuViews.noteRow(e, color: .systemOrange, size: 11,
                                      symbol: "exclamationmark.triangle.fill"))
        }

        // 设置
        menu.addItem(.separator())
        menu.addItem(accountSubmenu())
        menu.addItem(displaySubmenu())
        menu.addItem(intervalSubmenu())
        menu.addItem(billingSubmenu())

        menu.addItem(.separator())
        addAction(isRefreshing ? "刷新中…" : "立即刷新", #selector(refreshNow(_:)), key: "r", enabled: !isRefreshing)
        addAction("强制刷新（探测上游）", #selector(forceRefresh(_:)), key: "R", enabled: !isRefreshing)
        addAction("设置…", #selector(openSettings(_:)), key: ",")

        menu.addItem(.separator())
        var footer: [String] = []
        if let src = snapshot.usage.source { footer.append("数据源 \(src)") }
        footer.append("更新于 " + Fmt.clock.string(from: snapshot.fetchedAt))
        addView(MenuViews.noteRow(footer.joined(separator: " · "), color: .tertiaryLabelColor))
        addAction("退出", #selector(quit(_:)), key: "q")
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

    private func accountSubmenu() -> NSMenuItem {
        let root = NSMenuItem(title: "账号", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        if accounts.isEmpty {
            let item = NSMenuItem(title: "加载中…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            sub.addItem(item)
        }
        // 按平台分组，账号一多就不至于糊成一片
        let grouped = Dictionary(grouping: accounts, by: \.platform).sorted { $0.key < $1.key }
        for (platform, list) in grouped {
            if grouped.count > 1 { sub.addItem(.sectionHeader(title: platform)) }
            for a in list {
                let title = a.status == "active" ? a.displayName : "\(a.displayName)（\(a.status)）"
                let item = NSMenuItem(title: title, action: #selector(pickAccount(_:)), keyEquivalent: "")
                item.target = self
                item.tag = a.id
                item.state = a.id == Settings.shared.accountID ? .on : .off
                if let e = a.email, !e.isEmpty {
                    item.attributedTitle = subtitled(title, e)
                }
                sub.addItem(item)
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

    private func displaySubmenu() -> NSMenuItem {
        let root = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let mode = Settings.shared.displayMode

        let auto = NSMenuItem(title: "自动（占用最高的窗口）", action: #selector(pickDisplay(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = "auto"
        auto.state = mode == .auto ? .on : .off
        sub.addItem(auto)

        // 当前账号返回了哪些窗口就列哪些；再补上常见但本次没返回的档位，便于提前锁定
        var keys = snapshot.usage.windows.map(\.key)
        for k in ["five_hour", "seven_day", "seven_day_opus", "seven_day_fable", "seven_day_sonnet"] where !keys.contains(k) {
            keys.append(k)
        }
        sub.addItem(.sectionHeader(title: "固定显示"))
        for k in keys {
            let label = UsageWindow.labels[k] ?? k
            let available = snapshot.usage.window(key: k) != nil
            let item = NSMenuItem(title: available ? label : "\(label)（本账号暂无）",
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

        root.submenu = sub
        return root
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

    private func billingSubmenu() -> NSMenuItem {
        let root = NSMenuItem(title: "计费周期口径", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let mode = Settings.shared.cycleMode

        let rolling = NSMenuItem(title: "跟随 7 天滚动窗口", action: #selector(pickCycleMode(_:)), keyEquivalent: "")
        rolling.target = self
        rolling.representedObject = CycleMode.sevenDayWindow.rawValue
        rolling.state = mode == .sevenDayWindow ? .on : .off
        rolling.attributedTitle = subtitled("跟随 7 天滚动窗口", "推荐，与额度重置时间一致")
        sub.addItem(rolling)

        let monthly = NSMenuItem(title: "按自然月", action: nil, keyEquivalent: "")
        let monthlySub = NSMenu()
        monthlySub.autoenablesItems = false
        for day in 1...28 {
            let item = NSMenuItem(title: "每月 \(day) 号起", action: #selector(pickCycleMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CycleMode.monthly(day).rawValue
            item.state = mode == .monthly(day) ? .on : .off
            monthlySub.addItem(item)
        }
        monthly.submenu = monthlySub
        if case .monthly = mode { monthly.state = .on }
        sub.addItem(monthly)

        root.submenu = sub
        return root
    }

    // MARK: - 菜单动作

    @objc private func pickAccount(_ sender: NSMenuItem) {
        Settings.shared.accountID = sender.tag
        refresh()
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

    @objc private func pickCycleMode(_ sender: NSMenuItem) {
        Settings.shared.cycleMode = CycleMode(rawValue: sender.representedObject as? String ?? "7d")
        refresh()
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
