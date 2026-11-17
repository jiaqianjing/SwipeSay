import Foundation

/// Google Gemini (Generative Language API) with SSE streaming.
struct GeminiClient: LLMClient {
    let config: ProviderConfig

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        makeUsageStream(config: config, request: request) { continuation, meter in
            var generation: [String: Any] = [:]
            if request.expectsJSON { generation["responseMimeType"] = "application/json" }
            var body: [String: Any] = [
                "systemInstruction": ["parts": [["text": request.system]]],
                "contents": [["role": "user", "parts": [["text": request.user]]]],
            ]
            if !generation.isEmpty { body["generationConfig"] = generation }
            let model = config.model.hasPrefix("models/") ? String(config.model.dropFirst(7)) : config.model
            let url = try HTTP.url(config.baseURL, "/v1beta/models/\(model):streamGenerateContent?alt=sse")
            let req = try HTTP.jsonRequest(url, body: body, headers: ["x-goog-api-key": config.apiKey ?? ""])
            try await HTTP.streamSSE(req, continuation: continuation, meter: meter) { payload in
                guard let json = HTTP.parse(payload) else { return nil }
                if let err = json["error"] as? [String: Any] {
                    throw LLMError.invalidResponse(err["message"] as? String ?? payload)
                }
                if let metadata = json["usageMetadata"] as? [String: Any], let parsed = Self.parseUsage(metadata) {
                    meter.usage = parsed
                }
                guard let candidates = json["candidates"] as? [[String: Any]],
                      let content = candidates.first?["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else {
                    if let feedback = json["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
                        throw LLMError.refused(reason)
                    }
                    return nil
                }
                return parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            }
        }
    }

    /// `UsageMetadata`: `promptTokenCount` (cached included), `cachedContentTokenCount`, `candidatesTokenCount`
    /// and `thoughtsTokenCount` (thinking, billed as output). The docs don't say which stream chunks carry it,
    /// so the last one seen wins.
    /// https://ai.google.dev/api/generate-content (UsageMetadata)
    static func parseUsage(_ metadata: [String: Any]) -> TokenUsage? {
        guard let input = jsonInt(metadata["promptTokenCount"]) else { return nil }
        let output = (jsonInt(metadata["candidatesTokenCount"]) ?? 0) + (jsonInt(metadata["thoughtsTokenCount"]) ?? 0)
        return TokenUsage(input: input, output: output, cachedInput: jsonInt(metadata["cachedContentTokenCount"]) ?? 0)
    }

    func listModels() async throws -> [ModelInfo] {
        var req = URLRequest(url: try HTTP.url(config.baseURL, "/v1beta/models?pageSize=200"))
        req.setValue(config.apiKey ?? "", forHTTPHeaderField: "x-goog-api-key")
        let json = try await HTTP.getJSON(req)
        let models = json["models"] as? [[String: Any]] ?? []
        // The Model resource has no release date; ModelCatalog filters on `supportedGenerationMethods`.
        return models.compactMap { m -> ModelInfo? in
            guard let name = m["name"] as? String else { return nil }
            return ModelInfo(id: name.replacingOccurrences(of: "models/", with: ""),
                             generationMethods: m["supportedGenerationMethods"] as? [String] ?? [])
        }
    }
}
