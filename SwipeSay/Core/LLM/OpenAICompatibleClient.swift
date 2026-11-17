import Foundation

/// OpenAI Chat Completions protocol — used for OpenAI, DeepSeek and any compatible server
/// (OpenRouter, Moonshot, Qwen/DashScope, Zhipu, Ollama, LM Studio …).
struct OpenAICompatibleClient: LLMClient {
    let config: ProviderConfig

    private var headers: [String: String] {
        var h = ["Accept": "text/event-stream"]
        if let key = config.apiKey, !key.isEmpty { h["Authorization"] = "Bearer \(key)" }
        return h
    }

    /// gpt-5+/gpt-6 and o-series accept `reasoning_effort`; gpt-4.x and `chat-latest` reject it.
    static func isOpenAIReasoningModel(_ model: String) -> Bool {
        let m = model.lowercased()
        if m.contains("chat") { return false }
        return m.hasPrefix("gpt-5") || m.hasPrefix("gpt-6") || m.range(of: #"^o\d"#, options: .regularExpression) != nil
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        makeStream { continuation in
            var body: [String: Any] = [
                "model": config.model,
                "stream": true,
                "messages": [
                    ["role": "system", "content": request.system],
                    ["role": "user", "content": request.user],
                ],
            ]
            // Native JSON mode is reliable on OpenAI and DeepSeek; other servers vary, so prompt-only there.
            if request.expectsJSON, config.kind == .openAI || config.kind == .deepSeek {
                body["response_format"] = ["type": "json_object"]
            }
            // OpenAI reasoning models default to medium effort; translation doesn't need it.
            if config.kind == .openAI, Self.isOpenAIReasoningModel(config.model) {
                body["reasoning_effort"] = "low"
            }
            let url = try HTTP.url(config.baseURL, "/chat/completions")
            let req = try HTTP.jsonRequest(url, body: body, headers: headers)
            try await HTTP.streamSSE(req, continuation: continuation) { payload in
                guard let json = HTTP.parse(payload) else { return nil }
                if let err = json["error"] as? [String: Any] {
                    throw LLMError.invalidResponse(err["message"] as? String ?? "\(err)")
                }
                guard let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else { return nil }
                return delta["content"] as? String
            }
        }
    }

    func listModels() async throws -> [ModelInfo] {
        var req = URLRequest(url: try HTTP.url(config.baseURL, "/models"))
        for (k, v) in headers where k == "Authorization" { req.setValue(v, forHTTPHeaderField: k) }
        let json = try await HTTP.getJSON(req)
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap { m -> ModelInfo? in
            guard let id = m["id"] as? String else { return nil }
            // OpenAI: `created` is Unix seconds, `shutdown_date` a date string or null. Other servers may omit both.
            let created = (m["created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let shutdown = m["shutdown_date"] as? String
            return ModelInfo(id: id, created: created, deprecated: shutdown?.isEmpty == false)
        }
    }
}
