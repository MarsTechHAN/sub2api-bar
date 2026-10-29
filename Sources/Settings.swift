import Foundation

/// 菜单栏显示哪一档。`auto` = 显示当前占用最高的窗口。
enum DisplayMode: Equatable {
    case auto
    case window(String)

    var rawValue: String {
        switch self {
        case .auto: return "auto"
        case .window(let k): return k
        }
    }

    init(rawValue: String) {
        self = rawValue == "auto" || rawValue.isEmpty ? .auto : .window(rawValue)
    }
}

/// “计费周期”怎么算。Claude / Codex 的额度是 7 天滚动窗口，默认就跟着它走。
enum CycleMode: Equatable {
    case sevenDayWindow
    case monthly(Int)

    var rawValue: String {
        switch self {
        case .sevenDayWindow: return "7d"
        case .monthly(let d): return "month:\(d)"
        }
    }

    init(rawValue: String) {
        if rawValue.hasPrefix("month:"), let d = Int(rawValue.dropFirst(6)) {
            self = .monthly(max(1, min(28, d)))
        } else {
            self = .sevenDayWindow
        }
    }

    var label: String {
        switch self {
        case .sevenDayWindow: return "7d 窗口"
        case .monthly(let d): return "每月 \(d) 号"
        }
    }
}

/// 管理接口的认证方式。
///
/// - `apiKey`：旧版全权管理员 API Key，走 `X-Api-Key`。sub2api 0.2.19 起新建的
///   受限密钥（`adm_sc_` 开头）没有账号用量接口的权限，因此只对旧版全权密钥有效。
/// - `login`：管理员邮箱密码登录换取 JWT，走 `Authorization: Bearer`。受限密钥
///   读不到用量时用这个。密码只用于换令牌，不落盘；access/refresh token 存在配置文件里。
enum AuthMode: String {
    case apiKey = "api_key"
    case login = "login"

    var label: String {
        switch self {
        case .apiKey: return "管理员 API Key"
        case .login: return "管理员登录"
        }
    }
}

/// 全部配置落在 ~/.config/sub2api-quota/config.json，权限 0600，可以直接手改。
/// 没走钥匙串：这个 app 是本地自己编译的 ad-hoc 签名，每次重新编译代码签名都变，
/// 钥匙串会因为身份对不上而拒绝读取，反而更难用。
final class Settings {
    static let shared = Settings()

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sub2api-quota", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("config.json")

    /// 定时刷新在后台线程，登录令牌也可能在任意 async 任务里更新，store 要加锁。
    private let lock = NSRecursiveLock()
    private var store: [String: Any]

    private init() {
        store = Settings.loadFromDisk() ?? [:]
    }

    // MARK: - 读写

    private static func loadFromDisk() -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// 把所有配置项都写全，文件本身就是一份可读的说明。
    private func fillDefaults() {
        let defaults: [String: Any] = [
            "endpoint": "",
            "auth_mode": "api_key",       // api_key（旧版全权密钥）| login（管理员邮箱密码登录）
            "api_key": "",
            "admin_email": "",
            "access_token": "",
            "refresh_token": "",
            "token_expires_at": 0.0,      // Unix 时间戳；0 = 没有登录态
            "account_id": 0,
            "display_mode": "auto",       // auto | five_hour | seven_day | seven_day_fable | seven_day_sonnet | seven_day_opus
            "refresh_interval": 60,       // 秒，最小 15
            "cycle_mode": "7d",           // 7d（跟随 7 天滚动窗口）| month:N
            "show_gauge": true,
            "show_label": true,
            "title_gap": 5.5,             // 菜单栏里窗口名和百分比之间的间距（pt），普通空格是 3.58
            "title_align": "right",       // 百分比右对齐（right）还是左对齐（left）
        ]
        for (k, v) in defaults where store[k] == nil { store[k] = v }
    }

    private func save() {
        lock.lock()
        defer { lock.unlock() }
        fillDefaults()
        let fm = FileManager.default
        try? fm.createDirectory(at: Settings.directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: store,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        // 先建文件再改权限，避免 0644 的窗口期
        if !fm.fileExists(atPath: Settings.fileURL.path) {
            fm.createFile(atPath: Settings.fileURL.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        try? data.write(to: Settings.fileURL, options: .atomic)
        // 原子写会换 inode，权限要再设一次
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Settings.fileURL.path)
    }

    /// 外部（比如用户手改了文件）改动后重新读一次
    func reload() {
        lock.lock()
        defer { lock.unlock() }
        store = Settings.loadFromDisk() ?? [:]
    }

    private func string(_ key: String, _ fallback: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return (store[key] as? String) ?? fallback
    }

    private func int(_ key: String, _ fallback: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let v = store[key] as? Int { return v }
        if let v = store[key] as? Double { return Int(v) }
        return fallback
    }

    private func double(_ key: String, _ fallback: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if let v = store[key] as? Double { return v }
        if let v = store[key] as? Int { return Double(v) }
        return fallback
    }

    private func bool(_ key: String, _ fallback: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (store[key] as? Bool) ?? fallback
    }

    private func set(_ key: String, _ value: Any) {
        lock.lock()
        defer { lock.unlock() }
        store[key] = value
        save()
    }

    // MARK: - 配置项

    /// 服务地址，统一去掉结尾斜杠
    var endpoint: String {
        get { string("endpoint", "") }
        set { set("endpoint", Settings.normalize(newValue)) }
    }

    var authMode: AuthMode {
        get { AuthMode(rawValue: string("auth_mode", "api_key")) ?? .apiKey }
        set { set("auth_mode", newValue.rawValue) }
    }

    /// 旧版全权管理员 API Key（`admin-…`），通过 X-Api-Key 头发送。
    /// sub2api 0.2.19 的受限密钥是 `adm_sc_…`，没有用量接口权限，读不到配额。
    var apiKey: String {
        get { string("api_key", "") }
        set { set("api_key", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// 管理员登录用的邮箱。密码不保存，只保存登录换来的 token。
    var adminEmail: String {
        get { string("admin_email", "") }
        set { set("admin_email", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    var accessToken: String {
        get { string("access_token", "") }
        set { set("access_token", newValue) }
    }

    var refreshToken: String {
        get { string("refresh_token", "") }
        set { set("refresh_token", newValue) }
    }

    var tokenExpiresAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        let t: Double
        if let v = store["token_expires_at"] as? Double { t = v }
        else if let v = store["token_expires_at"] as? Int { t = Double(v) }
        else { t = 0 }
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    var hasLoginSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        let access = store["access_token"] as? String ?? ""
        let refresh = store["refresh_token"] as? String ?? ""
        return !access.isEmpty || !refresh.isEmpty
    }

    /// 登录成功后原子地写入令牌。refresh 为空时保留旧的（兼容服务端不回新 refresh token 的版本）。
    func saveTokens(_ tokens: AuthTokens) {
        lock.lock()
        defer { lock.unlock() }
        store["access_token"] = tokens.accessToken
        if !tokens.refreshToken.isEmpty {
            store["refresh_token"] = tokens.refreshToken
        }
        store["token_expires_at"] = Date()
            .addingTimeInterval(TimeInterval(max(0, tokens.expiresIn)))
            .timeIntervalSince1970
        save()
    }

    func clearLoginSession() {
        lock.lock()
        defer { lock.unlock() }
        store["access_token"] = ""
        store["refresh_token"] = ""
        store["token_expires_at"] = 0.0
        save()
    }

    var accountID: Int {
        get { int("account_id", 0) }
        set { set("account_id", newValue) }
    }

    var displayMode: DisplayMode {
        get { DisplayMode(rawValue: string("display_mode", "auto")) }
        set { set("display_mode", newValue.rawValue) }
    }

    var refreshInterval: Int {
        get { max(15, int("refresh_interval", 60)) }
        set { set("refresh_interval", max(15, newValue)) }
    }

    var cycleMode: CycleMode {
        get { CycleMode(rawValue: string("cycle_mode", "7d")) }
        set { set("cycle_mode", newValue.rawValue) }
    }

    var showGauge: Bool {
        get { bool("show_gauge", true) }
        set { set("show_gauge", newValue) }
    }

    var showLabel: Bool {
        get { bool("show_label", true) }
        set { set("show_label", newValue) }
    }

    /// 窗口名和百分比之间留多宽（pt）。系统字体的普通空格约 3.58pt，这里默认稍宽一点。
    /// 觉得不顺眼直接改配置文件里的 title_gap。
    var titleGap: Double {
        get { min(20, max(0, double("title_gap", 5.5))) }
        set { set("title_gap", min(20, max(0, newValue))) }
    }

    /// 百分比在预留宽度里靠哪边。宽度是按两位数钉死的，一位数时总有一个字宽的富余，
    /// 右对齐把它放在窗口名和数字之间（数字按列对齐），左对齐把它放在最右边。
    var titleAlignRight: Bool {
        get { string("title_align", "right") != "left" }
        set { set("title_align", newValue ? "right" : "left") }
    }

    var isConfigured: Bool {
        guard !endpoint.isEmpty else { return false }
        switch authMode {
        case .apiKey: return !apiKey.isEmpty
        case .login: return hasLoginSession
        }
    }

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
