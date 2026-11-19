// macOS only: see ChatGPTAuth.swift.
#if os(macOS)
import Foundation

/// Calls the Codex Responses endpoint with ChatGPT-plan credentials.
public struct ChatGPTClient: LLMClient {
    public let config: ProviderConfig

    /// Sent as `client_version` on the model catalog request, like Codex CLI does with its own version. The
    /// backend may leave out models that need a newer client, so keep this near the latest stable Codex release.
    public static let codexClientVersion = "0.169.0"

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        makeUsageStream(config: config, request: request) { continuation, meter in
            do {
                do {
                    try await run(request, continuation: continuation, meter: meter, forceRefresh: false, instructionsInInput: false)
                } catch LLMError.http(let code, _) where code == 401 {
                    try await run(request, continuation: continuation, meter: meter, forceRefresh: true, instructionsInInput: false)
                } catch LLMError.http(let code, let body) where code == 400 && body.localizedCaseInsensitiveContains("instructions") {
                    // Some backend versions only accept their own system instructions; move ours into the input.
                    try await run(request, continuation: continuation, meter: meter, forceRefresh: false, instructionsInInput: true)
                }
            } catch let error as LLMError where Self.isModelUnavailable(error) {
                throw LLMError.modelUnavailable(config.model)
            }
        }
    }

    private func authHeaders(_ creds: (token: String, accountID: String)) -> [String: String] {
        [
            "Authorization": "Bearer \(creds.token)",
            "chatgpt-account-id": creds.accountID,
            "originator": "codex_cli_rs",
        ]
    }

    /// Responses API `usage` (on the `response` of `response.completed`): `input_tokens` (cached included),
    /// `input_tokens_details.cached_tokens`, `output_tokens` (reasoning included).
    /// https://developers.openai.com/api/reference/resources/responses/streaming-events
    public static func parseUsage(_ usage: [String: Any]) -> TokenUsage? {
        guard let input = jsonInt(usage["input_tokens"]), let output = jsonInt(usage["output_tokens"]) else { return nil }
        let details = usage["input_tokens_details"] as? [String: Any]
        return TokenUsage(input: input, output: output, cachedInput: jsonInt(details?["cached_tokens"]) ?? 0)
    }

    private func run(_ request: LLMRequest,
                     continuation: AsyncThrowingStream<String, Error>.Continuation,
                     meter: UsageMeter,
                     forceRefresh: Bool,
                     instructionsInInput: Bool) async throws {
        let creds = try await ChatGPTAuth.shared.validCredentials(forceRefresh: forceRefresh)
        var input: [[String: Any]] = []
        if instructionsInInput {
            input.append(["type": "message", "role": "developer",
                          "content": [["type": "input_text", "text": request.system]]])
        }
        input.append(["type": "message", "role": "user",
                      "content": [["type": "input_text", "text": request.user]]])
        let body: [String: Any] = [
            "model": config.model,
            "instructions": instructionsInInput ? "You are a helpful assistant." : request.system,
            "input": input,
            "stream": true,
            "store": false,
            "reasoning": ["effort": "low"],
            "include": [],
        ]
        var headers = authHeaders(creds)
        headers["OpenAI-Beta"] = "responses=experimental"
        headers["session_id"] = UUID().uuidString
        headers["Accept"] = "text/event-stream"
        let req = try HTTP.jsonRequest(try HTTP.url(config.baseURL, "/responses"), body: body, headers: headers)
        try await HTTP.streamSSE(req, continuation: continuation, meter: meter) { payload in
            guard let json = HTTP.parse(payload), let type = json["type"] as? String else { return nil }
            switch type {
            case "response.output_text.delta":
                return json["delta"] as? String
            case "response.completed", "response.incomplete":
                let response = json["response"] as? [String: Any]
                if let usage = response?["usage"] as? [String: Any], let parsed = Self.parseUsage(usage) {
                    meter.usage = parsed
                }
                return nil
            case "response.failed", "error":
                let response = json["response"] as? [String: Any]
                if let usage = response?["usage"] as? [String: Any], let parsed = Self.parseUsage(usage) {
                    meter.usage = parsed
                }
                let err = (response?["error"] as? [String: Any]) ?? (json["error"] as? [String: Any])
                if err?["code"] as? String == "model_not_found" { throw LLMError.modelUnavailable(config.model) }
                throw LLMError.invalidResponse(err?["message"] as? String ?? json["message"] as? String ?? payload)
            default:
                return nil
            }
        }
    }

    /// The models this account can pick, from the same catalog endpoint Codex CLI uses
    /// (`GET {base}/models?client_version=…`, answering `{"models": [{"slug", "visibility", "priority", …}]}`).
    public func listModels() async throws -> [ModelInfo] {
        do {
            return try await fetchModels(forceRefresh: false)
        } catch LLMError.http(let code, _) where code == 401 {
            return try await fetchModels(forceRefresh: true)
        }
    }

    private func fetchModels(forceRefresh: Bool) async throws -> [ModelInfo] {
        let creds = try await ChatGPTAuth.shared.validCredentials(forceRefresh: forceRefresh)
        let base = try HTTP.url(config.baseURL, "/models")
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw LLMError.invalidResponse("无效的 Base URL：\(config.baseURL)")
        }
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "client_version", value: Self.codexClientVersion)]
        guard let url = comps.url else { throw LLMError.invalidResponse("无效的 Base URL：\(config.baseURL)") }
        var req = URLRequest(url: url, timeoutInterval: 10)
        for (k, v) in authHeaders(creds) { req.setValue(v, forHTTPHeaderField: k) }
        let json = try await HTTP.getJSON(req)
        guard let models = json["models"] as? [[String: Any]] else {
            throw LLMError.invalidResponse("模型列表格式无法识别")
        }
        // Codex shows only `visibility: "list"` models in its picker, ordered by `priority` (lower first).
        let listed = models
            .filter { ($0["visibility"] as? String ?? "list") == "list" }
            .compactMap { m -> (slug: String, priority: Int)? in
                guard let slug = m["slug"] as? String, !slug.isEmpty else { return nil }
                return (slug, m["priority"] as? Int ?? .max)
            }
            .sorted { $0.priority < $1.priority }
            .map { ModelInfo(id: $0.slug) }
        guard !listed.isEmpty else { throw LLMError.invalidResponse("服务没有返回可用模型") }
        return listed
    }

    /// The backend's ways of saying this account can't use the requested model. Codex CLI's tests use
    /// HTTP 400 `{"detail": "The 'x' model is not supported when using Codex with a ChatGPT account."}`
    /// for a retired model, and `model_not_found` as the error code otherwise.
    public static func isModelUnavailable(_ error: LLMError) -> Bool {
        guard case .http(let code, let body) = error, [400, 403, 404].contains(code) else { return false }
        let text = body.lowercased()
        return text.contains("model is not supported") || text.contains("model_not_found")
            || text.contains("model not found")
    }

    public init(config: ProviderConfig) {
        self.config = config
    }
}
#endif
