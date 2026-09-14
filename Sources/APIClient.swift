import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// sub2api 管理接口客户端。认证头是 X-Api-Key（不是 Authorization）。
final class APIClient: @unchecked Sendable {
    private let endpoint: String
    private let apiKey: String
    private let session: URLSession

    init(endpoint: String, apiKey: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - 请求

    private func request(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) throws -> URLRequest {
        guard var comps = URLComponents(string: endpoint + "/api/v1" + path) else {
            throw APIError(message: "地址无效：\(endpoint)")
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError(message: "地址无效：\(endpoint)") }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
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
            throw APIError(message: "网络错误：\(error.localizedDescription)")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if status == 404 { throw APIError(message: "接口不存在 (404)，请检查服务地址") }
            throw APIError(message: "返回不是 JSON (HTTP \(status))")
        }
        // 成功时 code 是数字 0；失败时 code 是字符串错误码，如 INVALID_TOKEN
        if let code = obj["code"] as? String, !code.isEmpty {
            let msg = obj["message"] as? String ?? code
            throw APIError(message: code == "INVALID_TOKEN" || code == "UNAUTHORIZED" ? "API Key 无效或权限不足" : "\(code)：\(msg)")
        }
        if let code = obj["code"] as? Int, code != 0 {
            throw APIError(message: obj["message"] as? String ?? "接口返回 code=\(code)")
        }
        guard status < 400 else { throw APIError(message: "HTTP \(status)") }
        guard let data = obj["data"] else { throw APIError(message: "返回缺少 data 字段") }
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

    /// sub2api 的历史接口只有自然日粒度，所以周期用量 = 从 start 所在自然日起累加。
    /// start 不在 00:00 时结果偏大，用 approximate 标出来，不假装精确。
    func fetchCycleStats(accountID: Int, start: Date, basis: String) async throws -> CycleStats {
        let days = BillingCycle.daysElapsed(since: start)
        let data = try await send(try request("GET", "/admin/accounts/\(accountID)/stats", query: ["days": "\(days)"]))
        let history = (data as? [String: Any])?["history"] as? [[String: Any]] ?? []
        let startDay = Fmt.isoDay.string(from: start)

        var agg = UsageStats()
        for row in history {
            guard let day = row["date"] as? String, day >= startDay else { continue }
            agg.requests += row["requests"] as? Int ?? 0
            agg.tokens += row["tokens"] as? Int ?? 0
            if let c = row["cost"] as? Double { agg.cost += c }
            else if let c = row["cost"] as? Int { agg.cost += Double(c) }
        }
        let midnight = Calendar.current.startOfDay(for: start) == start
        return CycleStats(start: start, end: Date(), stats: agg, basis: basis, approximate: !midnight)
    }

    /// 设置界面的“测试连接”，返回账号数。
    func testConnection() async throws -> Int {
        try await fetchAccounts().count
    }
}
