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

/// 服务器上被监控的一个账号。同时监控多个账号时靠颜色区分。
struct TrackedAccount: Equatable {
    var id: Int
    /// 调色板里的名字（blue / green …）或 `#RRGGBB`
    var color: String
    var showInBar: Bool

    init(id: Int, color: String, showInBar: Bool = true) {
        self.id = id
        self.color = color
        self.showInBar = showInBar
    }

    init?(dict d: [String: Any]) {
        guard let id = (d["id"] as? Int) ?? (d["id"] as? Double).map(Int.init), id > 0 else { return nil }
        self.init(id: id, color: d["color"] as? String ?? "", showInBar: d["show_in_bar"] as? Bool ?? true)
    }

    var dict: [String: Any] { ["id": id, "color": color, "show_in_bar": showInBar] }
}

/// 一台 sub2api 服务器：地址、认证，以及监控其中哪几个账号。
struct ServerConfig: Equatable {
    var id: String
    var name: String
    var endpoint: String
    var authMode: AuthMode
    var apiKey: String
    var adminEmail: String
    var accessToken: String
    var refreshToken: String
    /// 当前令牌是向哪个服务地址申请的。JWT 是绑定服务的，
    /// 换了地址还拿旧令牌去请求，等于把凭据发给另一个服务。
    var tokenEndpoint: String
    var tokenExpiresAt: Double
    /// 监控的账号，按添加顺序。空 = 首次刷新时自动选一个
    var accounts: [TrackedAccount]

    /// 监控多个账号时依次分配的颜色。避开红 / 橙：那两个留给“快用完了”。
    static let palette = ["blue", "green", "purple", "pink", "teal", "indigo", "brown", "yellow"]

    init(id: String = UUID().uuidString.lowercased(), name: String = "") {
        self.id = id
        self.name = name
        self.endpoint = ""
        self.authMode = .apiKey
        self.apiKey = ""
        self.adminEmail = ""
        self.accessToken = ""
        self.refreshToken = ""
        self.tokenEndpoint = ""
        self.tokenExpiresAt = 0
        self.accounts = []
    }

    init(dict d: [String: Any]) {
        func str(_ k: String) -> String { d[k] as? String ?? "" }
        func num(_ k: String) -> Double {
            if let v = d[k] as? Double { return v }
            if let v = d[k] as? Int { return Double(v) }
            return 0
        }
        self.init(id: str("id"), name: str("name"))
        endpoint = Settings.normalize(str("endpoint"))
        authMode = AuthMode(rawValue: str("auth_mode")) ?? .apiKey
        apiKey = str("api_key").trimmingCharacters(in: .whitespacesAndNewlines)
        adminEmail = str("admin_email")
        accessToken = str("access_token")
        refreshToken = str("refresh_token")
        tokenEndpoint = Settings.normalize(str("token_endpoint"))
        tokenExpiresAt = num("token_expires_at")
        if let list = d["accounts"] as? [[String: Any]] {
            accounts = list.compactMap(TrackedAccount.init(dict:))
        } else if num("account_id") > 0 {
            // 老格式：一台服务器只监控一个 account_id，颜色和显示开关挂在服务器上
            accounts = [TrackedAccount(id: Int(num("account_id")), color: str("color"),
                                       showInBar: d["show_in_bar"] as? Bool ?? true)]
        }
    }

    var dict: [String: Any] {
        [
            "id": id,
            "name": name,
            "endpoint": endpoint,
            "auth_mode": authMode.rawValue,
            "api_key": apiKey,
            "admin_email": adminEmail,
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "token_endpoint": tokenEndpoint,
            "token_expires_at": tokenExpiresAt,
            "accounts": accounts.map(\.dict),
        ]
    }

    func tracked(_ accountID: Int) -> TrackedAccount? { accounts.first { $0.id == accountID } }

    var hasLoginSession: Bool { !accessToken.isEmpty || !refreshToken.isEmpty }

    var tokenExpiryDate: Date? {
        tokenExpiresAt > 0 ? Date(timeIntervalSince1970: tokenExpiresAt) : nil
    }

    var isConfigured: Bool {
        guard !endpoint.isEmpty else { return false }
        switch authMode {
        case .apiKey: return !apiKey.isEmpty
        case .login: return hasLoginSession
        }
    }

    /// 没起名字就用域名
    var displayName: String {
        if !name.isEmpty { return name }
        if let host = URL(string: endpoint)?.host, !host.isEmpty { return host }
        return "新服务器"
    }

    mutating func clearLoginSession() {
        accessToken = ""
        refreshToken = ""
        tokenEndpoint = ""
        tokenExpiresAt = 0
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

    /// 只有一台服务器时，老版本把它的字段直接平铺在顶层，读到时搬进 servers。
    private static let legacyServerKeys = [
        "endpoint", "auth_mode", "api_key", "admin_email", "access_token",
        "refresh_token", "token_endpoint", "token_expires_at", "account_id",
    ]
    /// 已经不用的键，读到就删
    private static let obsoleteKeys = ["cycle_mode"]

    /// 定时刷新在后台线程，登录令牌也可能在任意 async 任务里更新，store 要加锁。
    private let lock = NSRecursiveLock()
    private var store: [String: Any]

    private init() {
        store = Settings.loadFromDisk() ?? [:]
        if migrate() { save() }
    }

    // MARK: - 读写

    private static func loadFromDisk() -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// 旧格式搬进 servers、补上缺的 id。返回 true 表示改过，需要写回。
    private func migrate() -> Bool {
        var changed = false
        if store["servers"] == nil {
            let hasLegacy = Settings.legacyServerKeys.contains { key in
                if let s = store[key] as? String { return !s.isEmpty }
                return store[key] != nil
            }
            if hasLegacy {
                var legacy: [String: Any] = [:]
                for k in Settings.legacyServerKeys { legacy[k] = store[k] }
                var server = ServerConfig(dict: legacy)
                server.id = UUID().uuidString.lowercased()
                store["servers"] = [server.dict]
            } else {
                store["servers"] = [[String: Any]]()
            }
            changed = true
        }
        for k in Settings.legacyServerKeys + Settings.obsoleteKeys where store[k] != nil {
            store.removeValue(forKey: k)
            changed = true
        }
        // 手改文件时可能漏写 id / color，补上，否则每次读出来都是新的 id；
        // 顺带把上一版“一台服务器一个 account_id”的写法换成 accounts 列表
        let before = rawServers
        var list = before.map(ServerConfig.init(dict:))
        var ids = Set<String>()
        var colors = Set<String>()
        for i in list.indices {
            if list[i].id.isEmpty || ids.contains(list[i].id) { list[i].id = UUID().uuidString.lowercased() }
            ids.insert(list[i].id)
            for j in list[i].accounts.indices {
                if list[i].accounts[j].color.isEmpty {
                    list[i].accounts[j].color = Settings.unusedColor(colors)
                }
                colors.insert(list[i].accounts[j].color)
            }
        }
        let after = list.map(\.dict)
        if !(before as NSArray).isEqual(to: after) {
            store["servers"] = after
            changed = true
        }
        return changed
    }

    /// 把所有配置项都写全，文件本身就是一份可读的说明。
    private func fillDefaults() {
        let defaults: [String: Any] = [
            "servers": [[String: Any]](),
            "display_mode": "auto",       // auto | five_hour | seven_day | seven_day_fable | seven_day_sonnet | seven_day_opus
            "refresh_interval": 60,       // 秒，最小 15
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

    /// 外部（比如用户手改了文件）改动后重新读一次。
    /// 文件被删掉时清空配置；但文件读不出来（手改出语法错误、权限暂时不对）
    /// 时保留上一次可用的配置，避免把内存里的登录令牌一起清掉。
    func reload() {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: Settings.fileURL.path) else {
            store = [:]
            return
        }
        guard let disk = Settings.loadFromDisk() else { return }
        store = disk
        if migrate() { save() }
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

    // MARK: - 服务器

    private var rawServers: [[String: Any]] {
        store["servers"] as? [[String: Any]] ?? []
    }

    var servers: [ServerConfig] {
        lock.lock()
        defer { lock.unlock() }
        return rawServers.map(ServerConfig.init(dict:))
    }

    /// 配好了、能拉数据的服务器
    var configuredServers: [ServerConfig] { servers.filter(\.isConfigured) }

    func server(_ id: String) -> ServerConfig? {
        servers.first { $0.id == id }
    }

    /// 读-改-写在同一把锁里完成，令牌刷新和设置窗口同时写也不会互相覆盖。
    func updateServer(_ id: String, _ body: (inout ServerConfig) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var list = servers
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        body(&list[i])
        list[i].endpoint = Settings.normalize(list[i].endpoint)
        list[i].tokenEndpoint = Settings.normalize(list[i].tokenEndpoint)
        store["servers"] = list.map(\.dict)
        save()
    }

    /// 新建一台空服务器，颜色取调色板里第一个还没被占的。
    @discardableResult
    func addServer() -> ServerConfig {
        lock.lock()
        defer { lock.unlock() }
        var list = servers
        let server = ServerConfig()
        list.append(server)
        store["servers"] = list.map(\.dict)
        save()
        return server
    }

    /// 调色板里第一个还没被占的颜色；都用过了就从头轮
    static func unusedColor(_ used: Set<String>) -> String {
        ServerConfig.palette.first { !used.contains($0) }
            ?? ServerConfig.palette[used.count % ServerConfig.palette.count]
    }

    /// 所有服务器上已经分配出去的颜色
    var usedColors: Set<String> { Set(servers.flatMap { $0.accounts.map(\.color) }) }

    /// 开始 / 停止监控某个账号。新监控的账号自动分一个没用过的颜色。
    func setTracked(_ accountID: Int, _ on: Bool, serverID: String) {
        lock.lock()
        defer { lock.unlock() }
        let color = Settings.unusedColor(usedColors)
        updateServer(serverID) { s in
            if on {
                if s.tracked(accountID) == nil { s.accounts.append(TrackedAccount(id: accountID, color: color)) }
            } else {
                s.accounts.removeAll { $0.id == accountID }
            }
        }
    }

    func updateTracked(_ accountID: Int, serverID: String, _ body: (inout TrackedAccount) -> Void) {
        updateServer(serverID) { s in
            if let i = s.accounts.firstIndex(where: { $0.id == accountID }) { body(&s.accounts[i]) }
        }
    }

    func removeServer(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        store["servers"] = servers.filter { $0.id != id }.map(\.dict)
        save()
    }

    /// 登录成功后原子地写入令牌。refresh 为空时保留旧的（兼容服务端不回新 refresh token 的版本）。
    /// endpoint 要跟令牌一起记下来，避免换服务地址后把旧令牌发过去。
    func saveTokens(_ tokens: AuthTokens, endpoint: String, serverID: String) {
        let normalized = Settings.normalize(endpoint)
        updateServer(serverID) { s in
            s.accessToken = tokens.accessToken
            if !tokens.refreshToken.isEmpty {
                s.refreshToken = tokens.refreshToken
            } else if !s.tokenEndpoint.isEmpty, s.tokenEndpoint != normalized {
                // 旧 refresh token 属于另一个服务，不能留着给新地址用
                s.refreshToken = ""
            }
            s.tokenEndpoint = normalized
            s.tokenExpiresAt = Date()
                .addingTimeInterval(TimeInterval(max(0, tokens.expiresIn)))
                .timeIntervalSince1970
        }
    }

    func clearLoginSession(serverID: String) {
        updateServer(serverID) { $0.clearLoginSession() }
    }

    // MARK: - 全局配置项

    var displayMode: DisplayMode {
        get { DisplayMode(rawValue: string("display_mode", "auto")) }
        set { set("display_mode", newValue.rawValue) }
    }

    var refreshInterval: Int {
        get { max(15, int("refresh_interval", 60)) }
        set { set("refresh_interval", max(15, newValue)) }
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

    var isConfigured: Bool { !configuredServers.isEmpty }

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
