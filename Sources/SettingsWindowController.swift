import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let endpointField = NSTextField()
    private let authModePop = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keyField = NSSecureTextField()
    private let emailField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let codeField = NSTextField()
    private let loginButton = NSButton()
    private let verifyButton = NSButton()
    private let logoutButton = NSButton()
    private let loginStatusLabel = NSTextField(labelWithString: "")
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let testButton = NSButton()
    private let onSave: () -> Void

    private var rootStack: NSStackView!
    private var keyRow: NSStackView!
    private var emailRow: NSStackView!
    private var passwordRow: NSStackView!
    private var loginStatusRow: NSStackView!
    private var codeRow: NSStackView!
    private var hintLabel: NSTextField!
    private var twoFATempToken: String?

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        // 设置窗口的标题就叫“设置”，App 名由系统补在别处，别自己再拼一遍
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        load()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private var currentAuthMode: AuthMode {
        authModePop.indexOfSelectedItem == 1 ? .login : .apiKey
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        /// 表单标签：右对齐 + 全角冒号，跟系统设置一致
        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text + "：")
            l.font = .systemFont(ofSize: NSFont.systemFontSize)
            l.alignment = .right
            l.textColor = .labelColor
            l.widthAnchor.constraint(equalToConstant: 96).isActive = true
            return l
        }

        func row(_ title: String, _ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: [label(title)] + views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            return stack
        }

        for f in [endpointField, keyField, emailField, passwordField, codeField] {
            f.font = .systemFont(ofSize: NSFont.systemFontSize)
            f.controlSize = .regular
            f.setContentHuggingPriority(.defaultLow, for: .horizontal)
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        endpointField.placeholderString = "https://sub2api.example.com"
        keyField.placeholderString = "admin-…（旧版全权密钥）"
        emailField.placeholderString = "admin@example.com"
        passwordField.placeholderString = "只用于换取令牌，不会保存"
        codeField.placeholderString = "6 位验证码"

        authModePop.addItems(withTitles: [AuthMode.apiKey.label, AuthMode.login.label])
        authModePop.target = self
        authModePop.action = #selector(authModeChanged(_:))
        authModePop.widthAnchor.constraint(equalToConstant: 220).isActive = true

        func configureButton(_ b: NSButton, _ title: String, _ action: Selector, small: Bool = false) {
            b.title = title
            b.bezelStyle = .push
            b.controlSize = small ? .small : .regular
            b.target = self
            b.action = action
        }
        configureButton(loginButton, "登录", #selector(login(_:)))
        configureButton(verifyButton, "验证", #selector(verify2FA(_:)), small: true)
        configureButton(logoutButton, "退出登录", #selector(logout(_:)), small: true)
        configureButton(testButton, "测试连接", #selector(test(_:)))

        loginStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.lineBreakMode = .byTruncatingTail
        loginStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.isHidden = true
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 4
        statusLabel.preferredMaxLayoutWidth = 540
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        hintLabel = NSTextField(wrappingLabelWithString: "")
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.preferredMaxLayoutWidth = 580

        let endpointRow = row("服务地址", [endpointField])
        let authSpacer = NSView()
        authSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let authRow = row("认证方式", [authModePop, authSpacer])
        keyRow = row("管理 API Key", [keyField])
        emailRow = row("管理员邮箱", [emailField])
        passwordRow = row("密码", [passwordField, loginButton])
        loginStatusRow = row("登录状态", [loginStatusLabel, logoutButton])
        codeRow = row("两步验证", [codeField, verifyButton])

        let statusRow = NSStackView(views: [statusIcon, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 5

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        saveButton.bezelStyle = .push
        // 默认按钮：回车触发，系统自动给它上强调色
        saveButton.keyEquivalent = "\r"

        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow(_:)))
        closeButton.bezelStyle = .push
        closeButton.keyEquivalent = "\u{1b}"   // Esc

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [testButton, spacer, closeButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        rootStack = NSStackView(views: [
            endpointRow, authRow, keyRow, emailRow, passwordRow,
            loginStatusRow, codeRow, hintLabel, statusRow, buttons,
        ])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 10
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            rootStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            rootStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            statusIcon.widthAnchor.constraint(equalToConstant: 13),
            statusIcon.heightAnchor.constraint(equalToConstant: 13),
        ])
        let rows: [NSView] = [endpointRow, authRow, keyRow, emailRow, passwordRow,
                              loginStatusRow, codeRow, hintLabel, statusRow, buttons]
        for view in rows {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }
    }

    private func load() {
        let s = Settings.shared
        endpointField.stringValue = s.endpoint
        keyField.stringValue = s.apiKey
        emailField.stringValue = s.adminEmail
        authModePop.selectItem(at: s.authMode == .login ? 1 : 0)
        updateAuthRows()
        updateLoginStatus()
        fitWindow()
    }

    private func updateAuthRows() {
        let login = currentAuthMode == .login
        keyRow.isHidden = login
        emailRow.isHidden = !login
        passwordRow.isHidden = !login
        loginStatusRow.isHidden = !login
        if !login {
            twoFATempToken = nil
            codeRow.isHidden = true
        }
        hintLabel.stringValue = login
            ? "密码只用于换取令牌，不会写入配置文件。令牌保存在 ~/.config/sub2api-quota/config.json（600），过期会自动续期。"
            : "旧版全权管理员 API Key（admin-…）可以读用量。新版受限密钥（adm_sc_…）只能读账号列表，读不到账号用量；受限于这一点，需要看配额时请改用「管理员登录」。"
        fitWindow()
    }

    private func updateLoginStatus() {
        let s = Settings.shared
        if s.hasLoginSession {
            let who = s.adminEmail.isEmpty ? "管理员" : s.adminEmail
            if let exp = s.tokenExpiresAt {
                loginStatusLabel.stringValue = "已登录：\(who) · 令牌有效至 \(Fmt.shortDateTime.string(from: exp))"
            } else {
                loginStatusLabel.stringValue = "已登录：\(who)"
            }
            loginStatusLabel.textColor = .secondaryLabelColor
            logoutButton.isHidden = false
        } else {
            loginStatusLabel.stringValue = "未登录"
            loginStatusLabel.textColor = .secondaryLabelColor
            logoutButton.isHidden = true
        }
    }

    /// 隐藏/显示认证相关的行之后，窗口高度跟着内容走，不留大片空白。
    private func fitWindow() {
        guard let window, let content = window.contentView else { return }
        rootStack.layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        let height = max(200, rootStack.fittingSize.height + 40)
        let oldTop = window.frame.maxY
        window.setContentSize(NSSize(width: 620, height: height))
        var frame = window.frame
        frame.origin.y = oldTop - frame.height
        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin.y = max(frame.origin.y, visible.minY + 40)
        }
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - 登录 / 两步验证

    @objc private func authModeChanged(_ sender: Any?) {
        updateAuthRows()
    }

    @objc private func login(_ sender: Any?) {
        let endpoint = Settings.normalize(endpointField.stringValue)
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        guard !endpoint.isEmpty else {
            setStatus("请先填写服务地址", ok: false)
            return
        }
        guard !email.isEmpty, !password.isEmpty else {
            setStatus("请填写管理员邮箱和密码", ok: false)
            return
        }
        loginButton.isEnabled = false
        setStatus("登录中…", ok: nil)
        Task { [weak self] in
            do {
                let outcome = try await AuthManager.login(endpoint: endpoint, email: email, password: password)
                await MainActor.run {
                    guard let self else { return }
                    self.loginButton.isEnabled = true
                    switch outcome {
                    case .tokens:
                        Settings.shared.authMode = .login
                        Settings.shared.adminEmail = email
                        Settings.shared.endpoint = endpoint
                        self.passwordField.stringValue = ""
                        self.twoFATempToken = nil
                        self.codeRow.isHidden = true
                        self.updateLoginStatus()
                        self.setStatus("登录成功", ok: true)
                        self.onSave()
                    case .needs2FA(let temp, let masked):
                        self.twoFATempToken = temp
                        self.codeRow.isHidden = false
                        self.codeField.stringValue = ""
                        self.setStatus("需要两步验证，请输入 \(masked ?? email) 的 6 位验证码", ok: nil)
                    }
                }
            } catch {
                let msg = SnapshotLoader.message(for: error)
                await MainActor.run {
                    self?.loginButton.isEnabled = true
                    self?.setStatus("登录失败：\(msg)", ok: false)
                }
            }
        }
    }

    @objc private func verify2FA(_ sender: Any?) {
        guard let temp = twoFATempToken else {
            setStatus("请先用邮箱密码登录", ok: false)
            return
        }
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6, Int(code) != nil else {
            setStatus("验证码是 6 位数字", ok: false)
            return
        }
        let endpoint = Settings.normalize(endpointField.stringValue)
        verifyButton.isEnabled = false
        setStatus("验证中…", ok: nil)
        Task { [weak self] in
            do {
                try await AuthManager.complete2FA(endpoint: endpoint, tempToken: temp, code: code)
                await MainActor.run {
                    guard let self else { return }
                    self.verifyButton.isEnabled = true
                    self.twoFATempToken = nil
                    self.codeRow.isHidden = true
                    Settings.shared.authMode = .login
                    Settings.shared.endpoint = endpoint
                    Settings.shared.adminEmail = self.emailField.stringValue
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.updateLoginStatus()
                    self.setStatus("登录成功", ok: true)
                    self.onSave()
                }
            } catch {
                let msg = SnapshotLoader.message(for: error)
                await MainActor.run {
                    self?.verifyButton.isEnabled = true
                    self?.setStatus("验证失败：\(msg)", ok: false)
                }
            }
        }
    }

    @objc private func logout(_ sender: Any?) {
        AuthManager.logout()
        updateLoginStatus()
        setStatus("已退出登录", ok: nil)
        onSave()
    }

    // MARK: - 测试 / 保存

    @objc private func test(_ sender: Any?) {
        let endpoint = Settings.normalize(endpointField.stringValue)
        let mode = currentAuthMode
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else {
            setStatus("请先填写服务地址", ok: false)
            return
        }
        if mode == .apiKey && key.isEmpty {
            setStatus("请先填写管理 API Key", ok: false)
            return
        }
        if mode == .login && !Settings.shared.hasLoginSession {
            setStatus("请先登录管理员账号", ok: false)
            return
        }

        testButton.isEnabled = false
        setStatus("连接中…", ok: nil)
        Task { [weak self] in
            do {
                let auth: APIClient.Auth
                if mode == .apiKey {
                    auth = .apiKey(key)
                } else {
                    try await AuthManager.ensureFreshToken(endpoint: endpoint)
                    let token = Settings.shared.accessToken
                    guard !token.isEmpty else { throw APIError("请先登录管理员账号") }
                    auth = .bearer(token)
                }
                let client = APIClient(endpoint: endpoint, auth: auth)
                let accounts = try await client.fetchAccounts()
                var note = "连接成功，读到 \(accounts.count) 个账号"
                var ok = true
                let id = Settings.shared.accountID != 0
                    ? Settings.shared.accountID
                    : accounts.first?.id
                if let id {
                    do {
                        let usage = try await client.fetchUsage(accountID: id, force: false)
                        note += usage.windows.isEmpty
                            ? "；用量接口可访问，但该账号暂无窗口数据"
                            : "；用量接口可用"
                    } catch {
                        ok = false
                        note += "；账号列表可用，但读不到用量：" + SnapshotLoader.message(for: error)
                    }
                }
                await MainActor.run {
                    self?.testButton.isEnabled = true
                    self?.setStatus(note, ok: ok)
                }
            } catch {
                let msg = SnapshotLoader.message(for: error)
                await MainActor.run {
                    self?.testButton.isEnabled = true
                    self?.setStatus("连接失败：\(msg)", ok: false)
                }
            }
        }
    }

    @objc private func save(_ sender: Any?) {
        let endpoint = Settings.normalize(endpointField.stringValue)
        guard !endpoint.isEmpty else {
            setStatus("服务地址不能为空", ok: false)
            return
        }
        switch currentAuthMode {
        case .apiKey:
            let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                setStatus("管理 API Key 不能为空", ok: false)
                return
            }
            Settings.shared.endpoint = endpoint
            Settings.shared.apiKey = key
            Settings.shared.authMode = .apiKey
        case .login:
            guard Settings.shared.hasLoginSession else {
                setStatus("请先点「登录」取得令牌", ok: false)
                return
            }
            Settings.shared.endpoint = endpoint
            Settings.shared.adminEmail = emailField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Settings.shared.authMode = .login
        }
        endpointField.stringValue = endpoint
        setStatus("已保存", ok: true)
        onSave()
    }

    @objc private func closeWindow(_ sender: Any?) { window?.close() }

    private func setStatus(_ text: String, ok: Bool?) {
        statusLabel.stringValue = text
        statusLabel.invalidateIntrinsicContentSize()
        let symbol: String?
        switch ok {
        case .some(true):
            statusLabel.textColor = .secondaryLabelColor
            statusIcon.contentTintColor = .systemGreen
            symbol = "checkmark.circle.fill"
        case .some(false):
            statusLabel.textColor = .systemOrange
            statusIcon.contentTintColor = .systemRed
            symbol = "exclamationmark.circle.fill"
        case .none:
            statusLabel.textColor = .secondaryLabelColor
            symbol = nil
        }
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            statusIcon.image = img
            statusIcon.isHidden = false
        } else {
            statusIcon.isHidden = true
        }
        fitWindow()
    }
}
