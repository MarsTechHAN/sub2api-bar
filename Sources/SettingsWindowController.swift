import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let endpointField = NSTextField()
    private let keyField = NSSecureTextField()
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton()
    private let onSave: () -> Void

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 210),
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

    private func buildUI() {
        guard let content = window?.contentView else { return }

        /// 表单标签：右对齐 + 全角冒号，跟系统设置一致
        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text + "：")
            l.font = .systemFont(ofSize: NSFont.systemFontSize)
            l.alignment = .right
            l.textColor = .labelColor
            return l
        }

        for f in [endpointField, keyField] {
            f.font = .systemFont(ofSize: NSFont.systemFontSize)
            f.controlSize = .regular
        }
        endpointField.placeholderString = "https://sub2api.example.com"
        keyField.placeholderString = "admin-…"

        let hint = NSTextField(wrappingLabelWithString:
            "保存在 ~/.config/sub2api-quota/config.json，权限 600，可直接手改。")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        statusIcon.imageScaling = .scaleProportionallyDown
        statusIcon.isHidden = true
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 2

        testButton.title = "测试连接"
        testButton.bezelStyle = .push
        testButton.controlSize = .regular
        testButton.target = self
        testButton.action = #selector(test(_:))

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        saveButton.bezelStyle = .push
        // 默认按钮：回车触发，系统自动给它上强调色
        saveButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow(_:)))
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1b}"   // Esc

        let grid = NSGridView(views: [
            [label("服务地址"), endpointField],
            [label("管理 API Key"), keyField],
            [NSGridCell.emptyContentView, hint],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.row(at: 2).topPadding = -2
        grid.translatesAutoresizingMaskIntoConstraints = false

        let status = NSStackView(views: [statusIcon, statusLabel])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 5

        // 左：辅助操作；右：取消 + 默认操作，macOS 的标准排布
        let buttons = NSStackView(views: [testButton, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(grid)
        content.addSubview(status)
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            status.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            statusIcon.widthAnchor.constraint(equalToConstant: 13),
            statusIcon.heightAnchor.constraint(equalToConstant: 13),

            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: status.bottomAnchor, constant: 14),
        ])
    }

    private func load() {
        endpointField.stringValue = Settings.shared.endpoint
        keyField.stringValue = Settings.shared.apiKey
    }

    /// 读取输入框里当前的值（而不是已保存的值），供测试连接使用。
    private func currentInput() -> (endpoint: String, key: String) {
        (Settings.normalize(endpointField.stringValue),
         keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func test(_ sender: Any?) {
        let (endpoint, key) = currentInput()
        guard !endpoint.isEmpty, !key.isEmpty else {
            setStatus("请先填写服务地址和 API Key", ok: false)
            return
        }
        testButton.isEnabled = false
        setStatus("连接中…", ok: nil)
        let client = APIClient(endpoint: endpoint, apiKey: key)
        Task { [weak self] in
            do {
                let n = try await client.testConnection()
                await MainActor.run {
                    self?.testButton.isEnabled = true
                    self?.setStatus("连接成功，读到 \(n) 个账号", ok: true)
                }
            } catch {
                let msg = (error as? APIError)?.message ?? error.localizedDescription
                await MainActor.run {
                    self?.testButton.isEnabled = true
                    self?.setStatus("连接失败：\(msg)", ok: false)
                }
            }
        }
    }

    @objc private func save(_ sender: Any?) {
        let (endpoint, key) = currentInput()
        guard !endpoint.isEmpty else {
            setStatus("服务地址不能为空", ok: false)
            return
        }
        Settings.shared.endpoint = endpoint
        Settings.shared.apiKey = key
        endpointField.stringValue = endpoint
        setStatus("已保存", ok: true)
        onSave()
    }

    @objc private func closeWindow(_ sender: Any?) { window?.close() }

    private func setStatus(_ text: String, ok: Bool?) {
        statusLabel.stringValue = text
        let symbol: String?
        switch ok {
        case .some(true):
            statusLabel.textColor = .secondaryLabelColor
            statusIcon.contentTintColor = .systemGreen
            symbol = "checkmark.circle.fill"
        case .some(false):
            statusLabel.textColor = .secondaryLabelColor
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
    }
}
