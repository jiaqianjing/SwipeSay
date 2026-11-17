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

    func listModels() async throws -> [String] {
        var req = URLRequest(url: try HTTP.url(config.baseURL, "/models"))
        for (k, v) in headers where k == "Authorization" { req.setValue(v, forHTTPHeaderField: k) }
        let json = try await HTTP.getJSON(req)
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap { $0["id"] as? String }.sorted()
    }
}
