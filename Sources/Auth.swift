import Foundation

struct AuthTokens {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
}

enum LoginOutcome {
    case tokens(AuthTokens)
    case needs2FA(tempToken: String, maskedEmail: String?)
}

/// 管理员登录相关接口（`/api/v1/auth/*`），不带头，返回 JWT。
enum AuthAPI {
    static func login(endpoint: String, email: String, password: String) async throws -> LoginOutcome {
        let data = try await APIClient.rawPOST(endpoint: endpoint, path: "/auth/login",
                                               body: ["email": email, "password": password])
        guard let d = data as? [String: Any] else { throw APIError("登录返回格式不对") }
        if (d["requires_2fa"] as? Bool) == true {
            guard let temp = d["temp_token"] as? String, !temp.isEmpty else {
                throw APIError("需要两步验证，但没有拿到验证会话")
            }
            return .needs2FA(tempToken: temp, maskedEmail: d["user_email_masked"] as? String)
        }
        return .tokens(try tokens(from: d))
    }

    static func verify2FA(endpoint: String, tempToken: String, code: String) async throws -> AuthTokens {
        let data = try await APIClient.rawPOST(endpoint: endpoint, path: "/auth/login/2fa",
                                               body: ["temp_token": tempToken, "totp_code": code])
        guard let d = data as? [String: Any] else { throw APIError("两步验证返回格式不对") }
        return try tokens(from: d)
    }

    static func refresh(endpoint: String, refreshToken: String) async throws -> AuthTokens {
        let data = try await APIClient.rawPOST(endpoint: endpoint, path: "/auth/refresh",
                                               body: ["refresh_token": refreshToken])
        guard let d = data as? [String: Any] else { throw APIError("刷新令牌返回格式不对") }
        return try tokens(from: d)
    }

    private static func tokens(from d: [String: Any]) throws -> AuthTokens {
        guard let access = d["access_token"] as? String, !access.isEmpty else {
            throw APIError("登录成功但没有拿到访问令牌")
        }
        let refresh = d["refresh_token"] as? String ?? ""
        let expires = d["expires_in"] as? Int ?? 86400
        // 服务端偶尔会回 0；别让它变成“刚拿到就过期”的死循环
        return AuthTokens(accessToken: access, refreshToken: refresh, expiresIn: max(60, expires))
    }
}

/// 同一时刻只允许一个刷新请求。refresh token 会轮换，并发刷新会让后一个请求
/// 拿着已作废的旧 token 去换，直接把登录态弄丢。
actor TokenGate {
    static let shared = TokenGate()
    private var inFlight: Task<Void, Error>?

    func coalesce(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        if let inFlight { return try await inFlight.value }
        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        try await task.value
    }
}

/// 根据配置决定这次请求用哪种认证，并在登录模式下自动续期。
enum AuthManager {
    static var isLoginMode: Bool { Settings.shared.authMode == .login }

    static func currentAuth(endpoint: String) async throws -> APIClient.Auth {
        let s = Settings.shared
        switch s.authMode {
        case .apiKey:
            guard !s.apiKey.isEmpty else { throw APIError("未配置管理 API Key") }
            return .apiKey(s.apiKey)
        case .login:
            try await ensureFreshToken(endpoint: endpoint)
            let token = Settings.shared.accessToken
            guard !token.isEmpty else {
                throw APIError("管理员登录已失效，请到设置里重新登录")
            }
            return .bearer(token)
        }
    }

    /// 登录模式下的 access token 快过期时自动用 refresh token 续期。
    static func ensureFreshToken(endpoint: String, force: Bool = false) async throws {
        guard isLoginMode else { return }
        let s = Settings.shared
        if !force, !s.accessToken.isEmpty,
           let exp = s.tokenExpiresAt, exp.timeIntervalSinceNow > 120 {
            return
        }
        try await TokenGate.shared.coalesce {
            let s = Settings.shared
            if !force, !s.accessToken.isEmpty,
               let exp = s.tokenExpiresAt, exp.timeIntervalSinceNow > 120 {
                return
            }
            let refresh = s.refreshToken
            guard !refresh.isEmpty else {
                throw APIError("管理员登录已过期，请到设置里重新登录")
            }
            let tokens = try await AuthAPI.refresh(endpoint: endpoint, refreshToken: refresh)
            Settings.shared.saveTokens(tokens)
        }
    }

    /// 服务端返回 401 时强制换一次 token，再重试请求。
    static func refreshAfterUnauthorized(endpoint: String) async throws -> APIClient.Auth {
        guard isLoginMode else {
            throw APIError("管理 API Key 无效或权限不足")
        }
        try await ensureFreshToken(endpoint: endpoint, force: true)
        let token = Settings.shared.accessToken
        guard !token.isEmpty else {
            throw APIError("管理员登录已失效，请到设置里重新登录")
        }
        return .bearer(token)
    }

    @discardableResult
    static func login(endpoint: String, email: String, password: String) async throws -> LoginOutcome {
        let outcome = try await AuthAPI.login(endpoint: endpoint, email: email, password: password)
        if case .tokens(let tokens) = outcome {
            Settings.shared.saveTokens(tokens)
        }
        return outcome
    }

    static func complete2FA(endpoint: String, tempToken: String, code: String) async throws {
        let tokens = try await AuthAPI.verify2FA(endpoint: endpoint, tempToken: tempToken, code: code)
        Settings.shared.saveTokens(tokens)
    }

    static func logout() {
        Settings.shared.clearLoginSession()
    }
}
