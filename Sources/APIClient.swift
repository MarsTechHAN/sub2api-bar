import Foundation

struct APIError: LocalizedError {
    let message: String
    var status: Int?
    var code: String?

    init(_ message: String, status: Int? = nil, code: String? = nil) {
        self.message = message
        self.status = status
        self.code = code
    }

    var errorDescription: String? { message }
    var isUnauthorized: Bool { status == 401 }
    var isForbidden: Bool { status == 403 || code == "FORBIDDEN" }
}

/// sub2api 管理接口客户端。
///
/// 认证有两种：
/// - 旧版全权管理员 API Key：`X-Api-Key`
/// - 管理员登录换来的 JWT：`Authorization: Bearer`
///
/// 新版的受限管理密钥（`adm_sc_`）虽然也能走 `X-Api-Key`，但 sub2api 没有把
/// 账号用量接口登记进受限密钥的权限目录，所以只能读账号列表，读不到配额。
final class APIClient: @unchecked Sendable {
    enum Auth {
        case apiKey(String)
        case bearer(String)
    }

    private let endpoint: String
    private let auth: Auth
    private let session: URLSession

    init(endpoint: String, auth: Auth) {
        self.endpoint = endpoint
        self.auth = auth
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    convenience init(endpoint: String, apiKey: String) {
        self.init(endpoint: endpoint, auth: .apiKey(apiKey))
    }

    // MARK: - 请求

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) throws -> URLRequest {
        guard var comps = URLComponents(string: endpoint + "/api/v1" + path) else {
            throw APIError("地址无效：\(endpoint)")
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError("地址无效：\(endpoint)") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        switch auth {
        case .apiKey(let key):
            req.setValue(key, forHTTPHeaderField: "X-Api-Key")
        case .bearer(let token):
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// 拆开 {code, message, data} 信封，返回 data。
    private func send(_ req: URLRequest) async throws -> Any {
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw APIError("网络错误：\(error.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return try APIClient.decode(data, status: status)
    }

    /// 不带头地打 `/api/v1/auth/*`，登录/刷新令牌用。
    static func rawPOST(endpoint: String, path: String, body: [String: Any]) async throws -> Any {
        guard let url = URL(string: endpoint + "/api/v1" + path) else {
            throw APIError("地址无效：\(endpoint)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError("网络错误：\(error.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return try decode(data, status: status)
    }

    private static func decode(_ data: Data, status: Int) throws -> Any {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if status == 404 { throw APIError("接口不存在 (404)，请检查服务地址", status: status) }
            throw APIError("返回不是 JSON (HTTP \(status))", status: status)
        }
        // 成功时 code 是数字 0；失败时 code 可能是字符串错误码（如 FORBIDDEN），
        // 也可能是 HTTP 状态码 + reason（如 401 + INVALID_CREDENTIALS）。
        if let code = obj["code"] as? String, !code.isEmpty {
            let msg = obj["message"] as? String ?? code
            let text: String
            switch code {
            case "INVALID_TOKEN", "UNAUTHORIZED":
                text = "API Key 或登录令牌无效或权限不足"
            default:
                text = "\(code)：\(msg)"
            }
            throw APIError(text, status: status, code: code)
        }
        if let code = obj["code"] as? Int, code != 0 {
            let reason = obj["reason"] as? String
            let msg = obj["message"] as? String ?? "接口返回 code=\(code)"
            let text: String
            switch reason {
            case "INVALID_CREDENTIALS":
                text = "邮箱或密码不正确"
            case "REFRESH_TOKEN_INVALID", "REFRESH_TOKEN_EXPIRED":
                text = "登录已过期，请重新登录"
            default:
                text = msg
            }
            throw APIError(text, status: status, code: reason)
        }
        guard status < 400 else { throw APIError("HTTP \(status)", status: status) }
        guard let data = obj["data"] else { throw APIError("返回缺少 data 字段", status: status) }
        return data
    }

    // MARK: - 具体接口

    func fetchAccounts() async throws -> [Account] {
        let data = try await send(try request("GET", "/admin/accounts", query: ["page": "1", "page_size": "200"]))
        let items: [[String: Any]]
        if let d = data as? [String: Any], let arr = d["items"] as? [[String: Any]] { items = arr }
        else if let arr = data as? [[String: Any]] { items = arr }
        else { items = [] }
        return items.compactMap(Account.init(json:))
    }

    /// 批量接口比单账号 GET 覆盖更全（openai 账号走单账号 + source=passive 会拿到 null）。
    /// force = true 会触发一次真实的上游探测，别放在自动轮询里。
    func fetchUsage(accountID: Int, force: Bool = false) async throws -> UsageSnapshot {
        let data = try await send(try request("POST", "/admin/accounts/usage/batch",
                                              body: ["account_ids": [accountID], "force": force]))
        guard let d = data as? [String: Any] else { return .empty }
        let key = String(accountID)
        if let errs = d["errors"] as? [String: Any], let e = errs[key] {
            return UsageSnapshot(windows: [], source: nil, sampledAt: nil, error: String(describing: e))
        }
        guard let usage = d["usage"] as? [String: Any], let mine = usage[key] as? [String: Any] else {
            return .empty
        }
        return UsageSnapshot(json: mine)
    }

    func fetchTodayStats(accountID: Int) async throws -> UsageStats {
        let data = try await send(try request("POST", "/admin/accounts/today-stats/batch",
                                              body: ["account_ids": [accountID]]))
        guard let d = data as? [String: Any] else { return UsageStats() }
        let key = String(accountID)
        if let stats = d["stats"] as? [String: Any], let mine = stats[key] as? [String: Any] {
            return UsageStats(json: mine)
        }
        if let mine = d[key] as? [String: Any] { return UsageStats(json: mine) }
        // 批量接口形态不符时退回单账号接口
        let single = try await send(try request("GET", "/admin/accounts/\(accountID)/today-stats"))
        return UsageStats(json: single as? [String: Any] ?? [:])
    }

    /// 统计接口只认自然日，按本机时区切日，和下面的日期字符串对齐。
    private static var timezone: String { TimeZone.current.identifier }

    /// `[fromDay 00:00, toDay 24:00)` 的整日汇总，日期是 `yyyy-MM-dd`。
    func fetchDayRangeStats(accountID: Int, fromDay: String, toDay: String) async throws -> UsageStats {
        let data = try await send(try request("GET", "/admin/usage/stats", query: [
            "account_id": "\(accountID)",
            "start_date": fromDay,
            "end_date": toDay,
            "timezone": APIClient.timezone,
        ]))
        let d = data as? [String: Any] ?? [:]
        var out = UsageStats()
        out.requests = d["total_requests"] as? Int ?? 0
        out.tokens = d["total_tokens"] as? Int ?? 0
        out.cost = APIClient.number(d["total_actual_cost"] ?? d["total_cost"])
        return out
    }

    /// 某一天里 `since` 之后的请求逐条累加。只用来补窗口起点所在那一天的零头。
    func fetchLogStats(accountID: Int, day: String, since: Date) async throws -> UsageStats {
        var out = UsageStats()
        var page = 1
        while page <= 50 {
            let data = try await send(try request("GET", "/admin/usage", query: [
                "account_id": "\(accountID)",
                "start_date": day,
                "end_date": day,
                "timezone": APIClient.timezone,
                "page": "\(page)",
                "page_size": "1000",
                "sort_by": "created_at",
                "sort_order": "desc",
            ]))
            let d = data as? [String: Any] ?? [:]
            let items = d["items"] as? [[String: Any]] ?? []
            var reachedStart = false
            for row in items {
                guard let at = DateParse.date(from: row["created_at"]) else { continue }
                // 倒序：一旦早于起点，后面的都更早
                if at < since { reachedStart = true; break }
                out.requests += 1
                out.tokens += ["input_tokens", "output_tokens", "cache_creation_tokens", "cache_read_tokens"]
                    .reduce(0) { $0 + (row[$1] as? Int ?? 0) }
                out.cost += APIClient.number(row["actual_cost"] ?? row["total_cost"])
            }
            let pages = d["pages"] as? Int ?? 1
            if reachedStart || items.isEmpty || page >= pages { break }
            page += 1
        }
        return out
    }

    private static func number(_ any: Any?) -> Double {
        if let v = any as? Double { return v }
        if let v = any as? Int { return Double(v) }
        return 0
    }

    /// 设置界面的“测试连接”，返回账号数。
    func testConnection() async throws -> Int {
        try await fetchAccounts().count
    }
}
