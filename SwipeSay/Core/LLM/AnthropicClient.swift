import Foundation

/// Anthropic Messages API over raw HTTP with SSE streaming.
struct AnthropicClient: LLMClient {
    let config: ProviderConfig

    private var baseHeaders: [String: String] {
        [
            "x-api-key": config.apiKey ?? "",
            "anthropic-version": "2023-06-01",
        ]
    }

    /// Models that accept `output_config.effort` (Claude 4.6+ generation and Opus 4.5).
    private var supportsEffort: Bool {
        let m = config.model
        let prefixes = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable", "claude-mythos",
                        "claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"]
        return prefixes.contains { m.hasPrefix($0) }
    }

    /// Models that support server-side refusal fallbacks.
    private var supportsFallbacks: Bool {
        ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(config.model)
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        makeStream { continuation in
            var body: [String: Any] = [
                "model": config.model,
                "max_tokens": max(request.maxTokens, 8192),
                "system": request.system,
                "stream": true,
                "messages": [["role": "user", "content": request.user]],
            ]
            var headers = baseHeaders
            headers["Accept"] = "text/event-stream"
            // Translation is latency sensitive: keep thinking light.
            if supportsEffort { body["output_config"] = ["effort": "low"] }
            if supportsFallbacks {
                body["fallbacks"] = "default"
                headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
            }
            let req = try HTTP.jsonRequest(try HTTP.url(config.baseURL, "/v1/messages"), body: body, headers: headers)
            try await HTTP.streamSSE(req, continuation: continuation) { payload in
                guard let json = HTTP.parse(payload), let type = json["type"] as? String else { return nil }
                switch type {
                case "content_block_delta":
                    guard let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta" else { return nil }
                    return delta["text"] as? String
                case "message_delta":
                    if let delta = json["delta"] as? [String: Any], delta["stop_reason"] as? String == "refusal" {
                        let details = delta["stop_details"] as? [String: Any]
                        throw LLMError.refused(details?["explanation"] as? String ?? "")
                    }
                    return nil
                case "error":
                    let err = json["error"] as? [String: Any]
                    throw LLMError.invalidResponse(err?["message"] as? String ?? payload)
                default:
                    return nil
                }
            }
        }
    }

    func listModels() async throws -> [String] {
        var req = URLRequest(url: try HTTP.url(config.baseURL, "/v1/models?limit=100"))
        for (k, v) in baseHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let json = try await HTTP.getJSON(req)
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap { $0["id"] as? String }
    }
}
