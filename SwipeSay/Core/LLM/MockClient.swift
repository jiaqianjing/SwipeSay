#if DEBUG
import Foundation
import AppKit

/// Debug-only canned responses for UI work without a real provider.
/// Launch with `-SwipeSayMock YES`; add `-SwipeSayDemo "some text"` to open a popup on launch.
struct MockClient: LLMClient {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "SwipeSayMock") }

    static let config: ProviderConfig = {
        var c = ProviderConfig(kind: .openAICompatible, name: "Mock")
        // `-SwipeSayMockModel <name>` sets the model shown in the popup footer (handy for screenshots).
        c.model = UserDefaults.standard.string(forKey: "SwipeSayMockModel") ?? "mock-model"
        return c
    }()

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        makeUsageStream(config: Self.config, request: request) { continuation, meter in
            let reply: String
            if request.system.contains("follow-up question") {
                let question = request.user.components(separatedBy: "<question>\n").last?
                    .components(separatedBy: "\n</question>").first ?? ""
                let turn = request.user.components(separatedBy: "<q>").count
                reply = """
                （第 \(turn) 轮 · Mock）关于「\(question)」：
                - 可以换成 enter，但语气会变：set foot in 强调「踏进去的那一刻」，常带“第一次 / 终于”的意味。
                - enter 更中性，只是陈述进入这个动作。
                例：No sooner had she entered the house than she felt it. 她一进屋就感觉到了。
                """
            } else if request.system.contains("learner's dictionary") {
                reply = #"{"term":"ubiquitous","lemma":"ubiquitous","phonetic":"/juːˈbɪkwɪtəs/","context_meaning":"无处不在的","senses":[{"pos":"adj.","meaning":"普遍存在的；无所不在的"}],"example":{"source":"Smartphones have become ubiquitous in modern life.","target":"智能手机在现代生活中已无处不在。"},"note":"常与 become 连用；名词形式 ubiquity。"}"#
            } else if request.system.contains("analysis_worthy") {
                reply = #"{"items":[{"text":"no sooner … than","kind":"pattern","phonetic":"","meaning":"一……就……","note":"no sooner 置于句首时主谓倒装"},{"text":"set foot in","kind":"phrase","phonetic":"","meaning":"踏入；进入","note":""},{"text":"inexplicable","kind":"word","phonetic":"/ˌɪnɪkˈsplɪkəbl/","meaning":"无法解释的","note":"比 strange 更正式"}],"analysis_worthy":true,"analysis_hint":"否定副词前置倒装"}"#
            } else if request.system.contains("Explain the sentence") {
                reply = #"{"kind":"structure","skeleton":"No sooner had she set foot in the house than she felt …","skeleton_translation":"她一进屋就感到……","chunks":[{"text":"No sooner had she set foot in the house","role":"倒装时间状语","explain":"no sooner 位于句首，助动词 had 提到主语前"},{"text":"than she felt","role":"主句","explain":"than 引出紧接着发生的动作"},{"text":"an inexplicable sense of dread","role":"宾语","explain":"inexplicable 修饰 sense，强调说不清的恐惧"}],"insights":["no sooner … than = as soon as，但更书面、更有戏剧性","看到否定词开头的句子，先找被提前的助动词"],"usage":"","paraphrase":"As soon as she entered the house, she felt a strange fear she couldn't explain."}"#
            } else {
                reply = "她刚一踏进那栋房子，就感到一种难以名状的恐惧。"
            }
            // Made-up counts (roughly 4 characters per token) so the usage page has data in mock mode.
            meter.usage = TokenUsage(input: (request.system.count + request.user.count) / 4 + 12,
                                     output: reply.count / 2 + 4)
            if request.expectsJSON {
                try await Task.sleep(nanoseconds: 600_000_000)
                continuation.yield(reply)
            } else {
                for ch in reply {
                    try await Task.sleep(nanoseconds: 35_000_000)
                    continuation.yield(String(ch))
                }
            }
        }
    }

    func listModels() async throws -> [ModelInfo] { [ModelInfo(id: "mock-model")] }
}
#endif
