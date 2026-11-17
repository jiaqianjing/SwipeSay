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

    /// Only the official OpenAI and DeepSeek endpoints get `stream_options`, since both document it.
    /// Compatible and custom servers never do: an unknown field must not risk breaking a working setup,
    /// so their usage is estimated locally instead.
    static func requestsStreamUsage(_ config: ProviderConfig) -> Bool {
        let host = URL(string: config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
        switch config.kind {
        case .openAI: return host == "api.openai.com"
        case .deepSeek: return host == "api.deepseek.com"
        default: return false
        }
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        makeUsageStream(config: config, request: request) { continuation, meter in
            var body: [String: Any] = [
                "model": config.model,
                "stream": true,
                "messages": [
                    ["role": "system", "content": request.system],
                    ["role": "user", "content": request.user],
                ],
            ]
            // Streamed chat completions carry no token counts unless asked. OpenAI then sends one extra final chunk
            // with empty `choices` and the whole request's `usage`; DeepSeek puts `usage` on its chunks.
            // Either way the last non-null `usage` wins.
            if Self.requestsStreamUsage(config) { body["stream_options"] = ["include_usage": true] }
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
            try await HTTP.streamSSE(req, continuation: continuation, meter: meter) { payload in
                guard let json = HTTP.parse(payload) else { return nil }
                if let err = json["error"] as? [String: Any] {
                    throw LLMError.invalidResponse(err["message"] as? String ?? "\(err)")
                }
                // Some compatible servers report usage unasked; take it when present.
                if let usage = json["usage"] as? [String: Any], let parsed = Self.parseUsage(usage) {
                    meter.usage = parsed
                }
                guard let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else { return nil }
                return delta["content"] as? String
            }
        }
    }

    /// Chat Completions `usage`: `prompt_tokens` (cached included), `completion_tokens` (reasoning included) and
    /// `prompt_tokens_details.cached_tokens`; DeepSeek also reports `prompt_cache_hit_tokens`.
    /// https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events
    /// https://api-docs.deepseek.com/api/create-chat-completion
    static func parseUsage(_ usage: [String: Any]) -> TokenUsage? {
        guard let input = jsonInt(usage["prompt_tokens"]), let output = jsonInt(usage["completion_tokens"]) else { return nil }
        let details = usage["prompt_tokens_details"] as? [String: Any]
        let cached = jsonInt(details?["cached_tokens"]) ?? jsonInt(usage["prompt_cache_hit_tokens"]) ?? 0
        return TokenUsage(input: input, output: output, cachedInput: cached)
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
