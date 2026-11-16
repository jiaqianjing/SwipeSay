import Foundation

/// Google Gemini (Generative Language API) with SSE streaming.
struct GeminiClient: LLMClient {
    let config: ProviderConfig

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        makeStream { continuation in
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
            try await HTTP.streamSSE(req, continuation: continuation) { payload in
                guard let json = HTTP.parse(payload) else { return nil }
                if let err = json["error"] as? [String: Any] {
                    throw LLMError.invalidResponse(err["message"] as? String ?? payload)
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

    func listModels() async throws -> [String] {
        var req = URLRequest(url: try HTTP.url(config.baseURL, "/v1beta/models?pageSize=200"))
        req.setValue(config.apiKey ?? "", forHTTPHeaderField: "x-goog-api-key")
        let json = try await HTTP.getJSON(req)
        let models = json["models"] as? [[String: Any]] ?? []
        return models.compactMap { m -> String? in
            guard let methods = m["supportedGenerationMethods"] as? [String], methods.contains("generateContent"),
                  let name = m["name"] as? String else { return nil }
            return name.replacingOccurrences(of: "models/", with: "")
        }
    }
}
