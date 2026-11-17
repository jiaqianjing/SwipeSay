import Foundation
import Combine

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case chatGPT
    case openAI
    case anthropic
    case gemini
    case deepSeek
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT 订阅"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .deepSeek: return "DeepSeek"
        case .openAICompatible: return "OpenAI 兼容"
        }
    }

    var symbol: String {
        switch self {
        case .chatGPT: return "person.crop.circle.badge.checkmark"
        case .openAI: return "sparkle"
        case .anthropic: return "asterisk"
        case .gemini: return "diamond"
        case .deepSeek: return "water.waves"
        case .openAICompatible: return "server.rack"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .chatGPT: return "https://chatgpt.com/backend-api/codex"
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .openAICompatible: return "http://localhost:11434/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .chatGPT: return "gpt-5.5"
        case .openAI: return "gpt-5-mini"
        case .anthropic: return "claude-opus-5-5"
        case .gemini: return "gemini-2.5-flash"
        case .deepSeek: return "deepseek-chat"
        case .openAICompatible: return ""
        }
    }

    /// Suggestions shown in the model picker before the live list is fetched.
    var suggestedModels: [String] {
        switch self {
        case .chatGPT: return ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"]
        case .openAI: return ["gpt-5-mini", "gpt-5", "gpt-4.1-mini"]
        case .anthropic: return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"]
        case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite"]
        case .deepSeek: return ["deepseek-chat", "deepseek-reasoner"]
        case .openAICompatible: return []
        }
    }

    var needsAPIKey: Bool { self != .chatGPT && self != .openAICompatible }
    var usesAPIKey: Bool { self != .chatGPT }
}

struct ProviderConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: ProviderKind
    var name: String
    var baseURL: String
    var model: String

    init(kind: ProviderKind, name: String? = nil) {
        self.kind = kind
        self.name = name ?? kind.displayName
        self.baseURL = kind.defaultBaseURL
        self.model = kind.defaultModel
    }

    var keychainAccount: String { "apikey.\(id.uuidString)" }

    var apiKey: String? {
        get { Keychain.get(keychainAccount) }
        nonmutating set { Keychain.set(newValue, for: keychainAccount) }
    }

    var isReady: Bool {
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        switch kind {
        case .chatGPT: return ChatGPTAuth.shared.isSignedIn
        case .openAICompatible: return !baseURL.isEmpty
        default: return !(apiKey ?? "").isEmpty
        }
    }
}

final class ProviderStore: ObservableObject {
    static let shared = ProviderStore()

    @Published var providers: [ProviderConfig] { didSet { persist() } }
    @Published var activeID: UUID? { didSet { persist() } }

    private let storageKey = "providers.v1"
    private let activeKey = "providers.active"

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([ProviderConfig].self, from: data), !saved.isEmpty {
            providers = saved
        } else {
            providers = [.chatGPT, .openAI, .anthropic, .gemini, .deepSeek].map { ProviderConfig(kind: $0) }
        }
        activeID = UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
    }

    var active: ProviderConfig? {
        if let id = activeID, let p = providers.first(where: { $0.id == id }) { return p }
        return providers.first(where: { $0.isReady })
    }

    func update(_ config: ProviderConfig) {
        guard let idx = providers.firstIndex(where: { $0.id == config.id }) else { return }
        providers[idx] = config
    }

    func add(_ kind: ProviderKind) -> ProviderConfig {
        let config = ProviderConfig(kind: kind, name: kind == .openAICompatible ? "自定义服务" : nil)
        providers.append(config)
        return config
    }

    func remove(_ id: UUID) {
        if let p = providers.first(where: { $0.id == id }) { p.apiKey = nil }
        providers.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) { UserDefaults.standard.set(data, forKey: storageKey) }
        UserDefaults.standard.set(activeID?.uuidString, forKey: activeKey)
    }
}
