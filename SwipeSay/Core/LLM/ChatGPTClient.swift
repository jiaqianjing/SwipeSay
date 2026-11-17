import Foundation

/// Calls the Codex Responses endpoint with ChatGPT-plan credentials.
struct ChatGPTClient: LLMClient {
    let config: ProviderConfig

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        makeStream { continuation in
            do {
                try await run(request, continuation: continuation, forceRefresh: false, instructionsInInput: false)
            } catch LLMError.http(let code, _) where code == 401 {
                try await run(request, continuation: continuation, forceRefresh: true, instructionsInInput: false)
            } catch LLMError.http(let code, let body) where code == 400 && body.localizedCaseInsensitiveContains("instructions") {
                // Some backend versions only accept their own system instructions; move ours into the input.
                try await run(request, continuation: continuation, forceRefresh: false, instructionsInInput: true)
            }
        }
    }

    private func run(_ request: LLMRequest,
                     continuation: AsyncThrowingStream<String, Error>.Continuation,
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
        let headers = [
            "Authorization": "Bearer \(creds.token)",
            "chatgpt-account-id": creds.accountID,
            "OpenAI-Beta": "responses=experimental",
            "originator": "codex_cli_rs",
            "session_id": UUID().uuidString,
            "Accept": "text/event-stream",
        ]
        let req = try HTTP.jsonRequest(try HTTP.url(config.baseURL, "/responses"), body: body, headers: headers)
        try await HTTP.streamSSE(req, continuation: continuation) { payload in
            guard let json = HTTP.parse(payload), let type = json["type"] as? String else { return nil }
            switch type {
            case "response.output_text.delta":
                return json["delta"] as? String
            case "response.failed", "error":
                let response = json["response"] as? [String: Any]
                let err = (response?["error"] as? [String: Any]) ?? (json["error"] as? [String: Any])
                throw LLMError.invalidResponse(err?["message"] as? String ?? json["message"] as? String ?? payload)
            default:
                return nil
            }
        }
    }

    func listModels() async throws -> [ModelInfo] {
        // The Codex backend has no stable public listing; offer the known plan models.
        ProviderKind.chatGPT.suggestedModels.map { ModelInfo(id: $0) }
    }
}
