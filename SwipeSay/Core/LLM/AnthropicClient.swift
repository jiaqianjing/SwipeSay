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
        makeUsageStream(config: config, request: request) { continuation, meter in
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
            var usage = AnthropicUsage()
            try await HTTP.streamSSE(req, continuation: continuation, meter: meter) { payload in
                guard let json = HTTP.parse(payload), let type = json["type"] as? String else { return nil }
                switch type {
                case "message_start":
                    let message = json["message"] as? [String: Any]
                    if let fields = message?["usage"] as? [String: Any] {
                        usage.merge(fields)
                        meter.usage = usage.tokenUsage
                    }
                    return nil
                case "content_block_delta":
                    guard let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta" else { return nil }
                    return delta["text"] as? String
                case "message_delta":
                    if let fields = json["usage"] as? [String: Any] {
                        usage.merge(fields)
                        meter.usage = usage.tokenUsage
                    }
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

    func listModels() async throws -> [ModelInfo] {
        var req = URLRequest(url: try HTTP.url(config.baseURL, "/v1/models?limit=100"))
        for (k, v) in baseHeaders { req.setValue(v, forHTTPHeaderField: k) }
        let json = try await HTTP.getJSON(req)
        let data = json["data"] as? [[String: Any]] ?? []
        return data.compactMap { m -> ModelInfo? in
            guard let id = m["id"] as? String else { return nil }
            // `created_at` is RFC 3339 and "may be set to an epoch value if the release date is unknown".
            let created = (m["created_at"] as? String).flatMap(Self.parseDate).flatMap { $0.timeIntervalSince1970 > 86_400 ? $0 : nil }
            return ModelInfo(id: id, created: created, deprecated: m["lifecycle"] as? String == "deprecated")
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

/// Messages API usage. `message_start` carries `message.usage`; each `message_delta.usage` holds cumulative counts
/// (always `output_tokens`, sometimes the input fields too), so later values replace earlier ones.
/// `input_tokens` excludes cache reads and writes; total input is the sum of all three.
/// https://platform.claude.com/docs/en/build-with-claude/streaming
/// https://platform.claude.com/docs/en/build-with-claude/prompt-caching
private struct AnthropicUsage {
    var input = 0
    var cacheCreation = 0
    var cacheRead = 0
    var output = 0

    mutating func merge(_ fields: [String: Any]) {
        if let v = jsonInt(fields["input_tokens"]) { input = v }
        if let v = jsonInt(fields["cache_creation_input_tokens"]) { cacheCreation = v }
        if let v = jsonInt(fields["cache_read_input_tokens"]) { cacheRead = v }
        if let v = jsonInt(fields["output_tokens"]) { output = v }
    }

    var tokenUsage: TokenUsage {
        TokenUsage(input: input + cacheCreation + cacheRead, output: output, cachedInput: cacheRead)
    }
}
