import Foundation

struct LLMRequest {
    var system: String
    var user: String
    /// Ask the provider for a JSON object when it supports a native JSON mode.
    var expectsJSON: Bool = false
    var maxTokens: Int = 4096
}

enum LLMError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case invalidResponse(String)
    case refused(String)
    case auth(String)
    /// The ChatGPT plan can't use this model (not in the plan, or retired).
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let model):
            let fallback = ProviderKind.chatGPT.defaultModel
            let hint = model == fallback ? "换一个模型" : "换一个模型（如 \(fallback)）"
            return "当前 ChatGPT 套餐不支持模型「\(model)」，或该模型已下线。请在 设置 › 模型服务 里\(hint)。"
        case .notConfigured: return "还没有可用的模型服务，请在设置里登录 ChatGPT 或填写 API Key。"
        case .http(let code, let body): return "请求失败（HTTP \(code)）：\(LLMError.summarize(body))"
        case .invalidResponse(let msg): return "无法解析模型返回：\(msg)"
        case .refused(let msg): return "模型拒绝了此请求\(msg.isEmpty ? "" : "：\(msg)")"
        case .auth(let msg): return "登录失效：\(msg)"
        }
    }

    private static func summarize(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = json["error"] as? String { return msg }
            if let msg = json["detail"] as? String { return msg }
            if let detail = json["detail"] as? [String: Any], let msg = detail["message"] as? String { return msg }
            if let msg = json["message"] as? String { return msg }
        }
        return String(body.prefix(240))
    }
}

protocol LLMClient {
    /// Streams text deltas.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
    /// The provider's full model listing, unfiltered; `ModelCatalog` decides what the picker shows.
    func listModels() async throws -> [ModelInfo]
}

extension LLMClient {
    func complete(_ request: LLMRequest) async throws -> String {
        var out = ""
        for try await delta in stream(request) { out += delta }
        return out
    }
}

enum LLMClientFactory {
    static func make(_ config: ProviderConfig) -> LLMClient {
        switch config.kind {
        case .openAI, .deepSeek, .openAICompatible: return OpenAICompatibleClient(config: config)
        case .anthropic: return AnthropicClient(config: config)
        case .gemini: return GeminiClient(config: config)
        case .chatGPT: return ChatGPTClient(config: config)
        }
    }
}

// MARK: - HTTP helpers

enum HTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    static func url(_ base: String, _ path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + path) else { throw LLMError.invalidResponse("无效的 Base URL：\(base)") }
        return url
    }

    static func jsonRequest(_ url: URL, body: [String: Any], headers: [String: String]) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Opens a streaming request and calls `onData` with the JSON payload of every SSE `data:` line.
    static func streamSSE(_ request: URLRequest,
                          continuation: AsyncThrowingStream<String, Error>.Continuation,
                          onData: (String) throws -> String?) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse("no response") }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 4000 { break } }
            throw LLMError.http(http.statusCode, body)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if let delta = try onData(payload), !delta.isEmpty { continuation.yield(delta) }
        }
    }

    static func getJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse("not a JSON object")
        }
        return json
    }

    static func parse(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Wraps an async producer into an AsyncThrowingStream with cancellation support.
func makeStream(_ body: @escaping (AsyncThrowingStream<String, Error>.Continuation) async throws -> Void)
    -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await body(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
