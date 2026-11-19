// macOS only: signing in with a ChatGPT plan borrows the Codex CLI's OAuth client, which is not
// something to ship in an App Store app. Kept out of the iOS build entirely.
#if os(macOS)
import Foundation
import AppKit
import CryptoKit
import Network

/// Sign in with a ChatGPT plan (Plus / Pro / Team …) using the same OAuth (PKCE) flow as the
/// open-source Codex CLI. Requests are then billed to the user's ChatGPT subscription.
///
/// Note: this relies on the Codex endpoints, which are not a documented public API and may change.
public final class ChatGPTAuth: ObservableObject {
    public static let shared = ChatGPTAuth()

    public struct Tokens: Codable {
        public var accessToken: String
        public var refreshToken: String
        public var idToken: String
        public var accountID: String
        public var expiresAt: Date
        public var email: String?
        public var plan: String?

        public init(accessToken: String, refreshToken: String, idToken: String, accountID: String, expiresAt: Date, email: String? = nil, plan: String? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.idToken = idToken
            self.accountID = accountID
            self.expiresAt = expiresAt
            self.email = email
            self.plan = plan
        }
    }

    public enum Status: Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String?, plan: String?)
        case failed(String)
    }

    @Published public private(set) var status: Status = .signedOut

    private static let issuer = "https://auth.openai.com"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let port: UInt16 = 1455
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let keychainAccount = "chatgpt.tokens"

    private var tokens: Tokens?
    private var server: OAuthCallbackServer?
    private var refreshTask: Task<Tokens, Error>?

    private init() {
        if let raw = Keychain.get(Self.keychainAccount), let data = raw.data(using: .utf8),
           let saved = try? JSONDecoder().decode(Tokens.self, from: data) {
            tokens = saved
            status = .signedIn(email: saved.email, plan: saved.plan)
        }
    }

    public var isSignedIn: Bool { tokens != nil }

    // MARK: Sign in

    @MainActor
    public func signIn() async {
        cancelSignIn()
        status = .signingIn
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(32)

        var comps = URLComponents(string: "\(Self.issuer)/oauth/authorize")!
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "originator", value: "codex_cli_rs"),
        ]

        do {
            let server = OAuthCallbackServer(port: Self.port)
            self.server = server
            try server.start()
            NSWorkspace.shared.open(comps.url!)
            let params = try await server.waitForCallback(timeout: 300)
            server.stop()
            self.server = nil
            guard params["state"] == state else { throw LLMError.auth("state 不匹配") }
            if let error = params["error"] { throw LLMError.auth(params["error_description"] ?? error) }
            guard let code = params["code"] else { throw LLMError.auth("没有收到授权码") }
            let tokens = try await exchange(code: code, verifier: verifier)
            save(tokens)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            server?.stop()
            server = nil
            status = .failed(error.localizedDescription)
        }
    }

    public func cancelSignIn() {
        server?.stop()
        server = nil
        if status == .signingIn { status = tokens == nil ? .signedOut : .signedIn(email: tokens?.email, plan: tokens?.plan) }
    }

    /// Reuse the credentials of an existing Codex CLI login (~/.codex/auth.json).
    @MainActor
    public func importFromCodexCLI() -> Bool {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let url = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = json["tokens"] as? [String: Any],
              let access = t["access_token"] as? String,
              let refresh = t["refresh_token"] as? String,
              let idToken = t["id_token"] as? String else {
            status = .failed("没有找到 Codex CLI 的登录信息（~/.codex/auth.json）")
            return false
        }
        guard let tokens = Self.makeTokens(access: access, refresh: refresh, idToken: idToken,
                                           accountHint: t["account_id"] as? String) else {
            status = .failed("Codex 登录信息格式无法识别")
            return false
        }
        save(tokens)
        return true
    }

    public func signOut() {
        tokens = nil
        Keychain.set(nil, for: Self.keychainAccount)
        DispatchQueue.main.async { self.status = .signedOut }
    }

    // MARK: Tokens

    /// Returns a valid access token, refreshing it when it is about to expire.
    public func validCredentials(forceRefresh: Bool = false) async throws -> (token: String, accountID: String) {
        guard let current = tokens else { throw LLMError.notConfigured }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > 120 {
            return (current.accessToken, current.accountID)
        }
        if let task = refreshTask {
            let t = try await task.value
            return (t.accessToken, t.accountID)
        }
        let task = Task { try await self.refresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let t = try await task.value
            save(t)
            return (t.accessToken, t.accountID)
        } catch {
            if case LLMError.http(let code, _) = error, code == 400 || code == 401 {
                signOut()
                throw LLMError.auth("请重新登录 ChatGPT")
            }
            throw error
        }
    }

    private func exchange(code: String, verifier: String) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "\(Self.issuer)/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", Self.redirectURI),
            ("client_id", Self.clientID),
            ("code_verifier", verifier),
        ]
        req.httpBody = form.map { "\($0.0)=\(Self.formEncode($0.1))" }.joined(separator: "&").data(using: .utf8)
        let json = try await HTTP.getJSON(req)
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String,
              let idToken = json["id_token"] as? String,
              let tokens = Self.makeTokens(access: access, refresh: refresh, idToken: idToken, accountHint: nil) else {
            throw LLMError.auth("令牌响应不完整")
        }
        return tokens
    }

    private func refresh(_ current: Tokens) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "\(Self.issuer)/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "scope": "openid profile email",
        ])
        let json = try await HTTP.getJSON(req)
        let access = json["access_token"] as? String ?? current.accessToken
        let refresh = json["refresh_token"] as? String ?? current.refreshToken
        let idToken = json["id_token"] as? String ?? current.idToken
        guard let t = Self.makeTokens(access: access, refresh: refresh, idToken: idToken, accountHint: current.accountID) else {
            throw LLMError.auth("刷新令牌失败")
        }
        return t
    }

    private func save(_ t: Tokens) {
        tokens = t
        if let data = try? JSONEncoder().encode(t), let s = String(data: data, encoding: .utf8) {
            Keychain.set(s, for: Self.keychainAccount)
        }
        DispatchQueue.main.async { self.status = .signedIn(email: t.email, plan: t.plan) }
    }

    // MARK: JWT helpers

    private static func makeTokens(access: String, refresh: String, idToken: String, accountHint: String?) -> Tokens? {
        let idClaims = decodeJWT(idToken) ?? [:]
        let accessClaims = decodeJWT(access) ?? [:]
        let auth = (idClaims["https://api.openai.com/auth"] as? [String: Any])
            ?? (accessClaims["https://api.openai.com/auth"] as? [String: Any]) ?? [:]
        guard let accountID = (auth["chatgpt_account_id"] as? String) ?? accountHint else { return nil }
        let exp = (accessClaims["exp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date().addingTimeInterval(3600)
        let profile = accessClaims["https://api.openai.com/profile"] as? [String: Any]
        let email = (idClaims["email"] as? String) ?? (profile?["email"] as? String)
        return Tokens(accessToken: access, refreshToken: refresh, idToken: idToken, accountID: accountID,
                      expiresAt: exp, email: email, plan: auth["chatgpt_plan_type"] as? String)
    }

    private static func decodeJWT(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func randomURLSafe(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Minimal one-shot HTTP server that receives the OAuth redirect on localhost.
public final class OAuthCallbackServer {
    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let queue = DispatchQueue(label: "swipesay.oauth")

    public init(port: UInt16) { self.port = port }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.finish(.failure(LLMError.auth("无法监听端口 \(self?.port ?? 0)：\(error.localizedDescription)")))
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else { return cont.resume(throwing: CancellationError()) }
                self.continuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(LLMError.auth("登录超时")))
                }
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let firstLine = request.split(separator: "\r\n").first else { conn.cancel(); return }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, let comps = URLComponents(string: "http://localhost" + parts[1]),
                  comps.path == "/auth/callback" else {
                self.respond(conn, status: "404 Not Found", body: "Not found")
                return
            }
            var params: [String: String] = [:]
            for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
            let ok = params["code"] != nil
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><title>SwipeSay</title>
            <style>body{font-family:-apple-system,sans-serif;display:flex;height:100vh;align-items:center;justify-content:center;background:#FFF8E6;color:#333}
            .card{text-align:center}.t{font-size:22px;font-weight:600;margin-bottom:8px}</style></head>
            <body><div class="card"><div class="t">\(ok ? "✅ 已登录 SwipeSay" : "登录未完成")</div>
            <div>\(ok ? "可以关闭此页面，回到 SwipeSay。" : "请回到 SwipeSay 重试。")</div></div></body></html>
            """
            self.respond(conn, status: "200 OK", body: html, contentType: "text/html; charset=utf-8")
            self.finish(.success(params))
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String, contentType: String = "text/plain") {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in conn.cancel() })
    }
}
#endif
