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
        // Translation is short, high-volume work: the efficient tier is fast and good enough.
        // Luna is also the one model every ChatGPT plan (Free/Go included) can use in Codex.
        case .chatGPT: return "gpt-6-luna"
        case .openAI: return "gpt-6-luna"
        case .anthropic: return "claude-haiku-5-5"
        // Checked 2026-11-17. Gemini: https://aistudio.google.com/docs/models recommends 3.5 Flash-Lite for
        // low-latency, cost-efficient work (2.5 Flash / Pro are deprecated and reroute on 2026-12-01).
        // DeepSeek: https://api-docs.deepseek.com/updates/ retired deepseek-chat / deepseek-reasoner on
        // 2026-07-24; https://api-docs.deepseek.com/api/list-models/ lists deepseek-flash and deepseek-v4-pro.
        case .gemini: return "gemini-3.5-flash-lite"
        case .deepSeek: return "deepseek-flash"
        case .openAICompatible: return ""
        }
    }

    /// Suggestions shown in the model picker before the live list is fetched.
    var suggestedModels: [String] {
        switch self {
        case .chatGPT: return ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.1-sol"]
        case .openAI: return ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-5.4-mini"]
        case .anthropic: return ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2"]
        case .gemini: return ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-4-hydrogen", "gemini-3.8-flash"]
        case .deepSeek: return ["deepseek-flash", "deepseek-v4-pro"]
        case .openAICompatible: return []
        }
    }

    /// Kinds this build offers. The ChatGPT subscription sign-in borrows the Codex CLI's OAuth client and a
    /// localhost callback, which only the Mac app can do; the iOS app uses API keys only.
    static var available: [ProviderKind] {
        #if os(macOS)
        return allCases
        #else
        return allCases.filter { $0 != .chatGPT }
        #endif
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

    /// Host the requests go to, e.g. "api.openai.com" (shown when asking for consent).
    var endpointHost: String {
        URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.host ?? baseURL
    }

    var isReady: Bool {
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        switch kind {
        case .chatGPT:
            #if os(macOS)
            return ChatGPTAuth.shared.isSignedIn
            #else
            return false
            #endif
        case .openAICompatible: return !baseURL.isEmpty
        default: return !(apiKey ?? "").isEmpty
        }
    }
}

final class ProviderStore: ObservableObject {
    static let shared = ProviderStore()

    @Published var providers: [ProviderConfig] { didSet { persist() } }
    @Published var activeID: UUID? { didSet { persist() } }

    private let defaults = SharedStorage.defaults
    private let storageKey = "providers.v1"
    private let activeKey = "providers.active"
    /// Debug mock mode keeps providers in memory, so trying things out never rewrites the real settings.
    private var inMemory = false
    private var isReloading = false

    private init() {
        #if DEBUG
        if MockClient.isEnabled {
            inMemory = true
            providers = ProviderKind.available.filter { $0 != .openAICompatible }.map { ProviderConfig(kind: $0) }
            // `-SwipeSayDemoBaseURL <url>` adds and selects an OpenAI-compatible provider at that URL
            // (for example a local fake server), so the settings flow can be exercised end to end.
            if let url = UserDefaults.standard.string(forKey: "SwipeSayDemoBaseURL") {
                var local = ProviderConfig(kind: .openAICompatible, name: "本地测试")
                local.baseURL = url
                local.model = "test-model"
                providers.append(local)
                activeID = local.id
            }
            return
        }
        #endif
        providers = Self.loadSaved(from: defaults, key: storageKey)
        activeID = defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
    }

    private static func loadSaved(from defaults: UserDefaults, key: String) -> [ProviderConfig] {
        var loaded: [ProviderConfig] = []
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([ProviderConfig].self, from: data), !saved.isEmpty {
            // Move configs still on an old built-in default to the current one; user-picked models stay.
            let legacyDefaults: [ProviderKind: Set<String>] = [
                .chatGPT: ["gpt-5.5"], .openAI: ["gpt-5-mini"], .anthropic: ["claude-opus-5-5"],
                // Deprecated or retired upstream (see `defaultModel`); gemini-2.5-flash-lite is still served.
                .gemini: ["gemini-2.5-flash", "gemini-2.5-pro"], .deepSeek: ["deepseek-chat", "deepseek-reasoner"],
            ]
            loaded = saved.filter { ProviderKind.available.contains($0.kind) }.map { config in
                var c = config
                if legacyDefaults[c.kind]?.contains(c.model) == true { c.model = c.kind.defaultModel }
                return c
            }
        }
        return loaded.isEmpty
            ? ProviderKind.available.filter { $0 != .openAICompatible }.map { ProviderConfig(kind: $0) }
            : loaded
    }

    #if os(iOS)
    /// Re-reads providers the app may have changed since this process started (the Safari extension's process
    /// can live a long time). Does not write anything back.
    func reloadFromStorage() {
        guard !inMemory else { return }
        isReloading = true
        defer { isReloading = false }
        providers = Self.loadSaved(from: defaults, key: storageKey)
        activeID = defaults.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
    }
    #endif

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
        guard !inMemory, !isReloading else { return }
        if let data = try? JSONEncoder().encode(providers) { defaults.set(data, forKey: storageKey) }
        defaults.set(activeID?.uuidString, forKey: activeKey)
    }
}
