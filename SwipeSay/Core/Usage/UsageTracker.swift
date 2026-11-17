import Foundation

/// What a model request was for. Stored as its raw value, so never rename a case.
enum UsageKind: String, CaseIterable, Identifiable, Sendable {
    case translate
    case word
    case keyItems
    case analysis
    case followUp
    case test
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .translate: return "翻译"
        case .word: return "查单词"
        case .keyItems: return "重点表达"
        case .analysis: return "句子解析"
        case .followUp: return "追问"
        case .test: return "测试连接"
        case .other: return "其他"
        }
    }
}

/// Token counts as reported by the provider for one request.
struct TokenUsage: Sendable, Hashable {
    /// All prompt tokens, cached ones included.
    var input: Int
    /// All generated tokens, reasoning / thinking included.
    var output: Int
    /// The part of `input` served from the provider's prompt cache.
    var cachedInput: Int = 0

    var total: Int { input + output }
}

/// Filled in by a client while it reads a stream; read once the stream ends.
/// Only touched from the task that runs the stream, so no locking is needed.
final class UsageMeter: @unchecked Sendable {
    /// Counts reported by the provider, if any.
    var usage: TokenUsage?
    /// Running estimate of the streamed output; only the count is kept, never the text.
    private var outputUnits = TokenEstimator.Units()

    func addOutput(_ delta: String) { outputUnits.add(delta) }

    /// A local estimate for when the provider reported nothing. Skipped for requests that failed before any output
    /// arrived (e.g. an auth or HTTP error), since those prompts were most likely never processed.
    func estimate(for request: LLMRequest, success: Bool) -> TokenUsage? {
        guard usage == nil, success || outputUnits.hasText else { return nil }
        var input = TokenEstimator.Units()
        input.add(request.system)
        input.add(request.user)
        return TokenUsage(input: input.tokens, output: outputUnits.tokens)
    }
}

/// Rough token estimate for text the provider gave no counts for. Real tokenizers differ per model, so this is
/// only good to within tens of percent and the UI always marks such numbers as estimates:
/// - CJK characters (Han, kana, Hangul, CJK and full-width punctuation): about 1 token each.
/// - Everything else (Latin text, digits, spaces, symbols): about 4 characters per token.
enum TokenEstimator {
    struct Units {
        private var cjk = 0
        private var other = 0

        var hasText: Bool { cjk + other > 0 }
        var tokens: Int { cjk + (other + 3) / 4 }

        mutating func add(_ text: String) {
            for scalar in text.unicodeScalars {
                if TokenEstimator.isCJK(scalar) { cjk += 1 } else { other += 1 }
            }
        }
    }

    static func tokens(_ text: String) -> Int {
        var units = Units()
        units.add(text)
        return units.tokens
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK symbols and punctuation
             0x3040...0x30FF,   // Hiragana, Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK compatibility ideographs
             0xFF00...0xFFEF,   // Half-width and full-width forms
             0x20000...0x2FA1F: // CJK Extensions B and later
            return true
        default:
            return false
        }
    }
}

/// One finished request (or cache hit), ready to be added to the daily totals.
struct UsageEvent: Sendable {
    var date: Date
    var providerKind: String
    var providerName: String
    var model: String
    var kind: UsageKind
    /// Counts reported by the provider.
    var usage: TokenUsage?
    /// Local estimate, used only when `usage` is nil; stored apart from reported counts.
    var estimated: TokenUsage? = nil
    var success: Bool
    var cacheHit: Bool = false
}

/// The single entry point for recording model usage. Calls return immediately; the write happens on a
/// background actor, so recording never blocks the UI. Only numbers and model names are stored — never text.
enum UsageTracker {
    /// Posted on the main thread after the stored totals change.
    static let didChange = Notification.Name("SwipeSay.usageDidChange")

    private static let store = Task.detached(priority: .utility) { () -> UsageStore? in
        guard let container = UsageStore.makeContainer() else { return nil }
        let store = UsageStore(modelContainer: container)
        #if DEBUG
        if MockClient.isEnabled { await store.seedDemoData() }
        #endif
        return store
    }

    /// Records one model request. `usage` is nil when the provider reported no token counts; `estimated` is then
    /// a local guess (see `TokenEstimator`), kept separate so the page can label it.
    static func record(provider: ProviderConfig, kind: UsageKind, usage: TokenUsage?, estimated: TokenUsage? = nil,
                       success: Bool, date: Date = Date()) {
        submit(UsageEvent(date: date, providerKind: provider.kind.rawValue, providerName: provider.name,
                          model: provider.model, kind: kind, usage: usage, estimated: usage == nil ? estimated : nil,
                          success: success))
    }

    /// Records a result served from a local cache (no tokens spent).
    static func recordCacheHit(provider: ProviderConfig, kind: UsageKind, date: Date = Date()) {
        submit(UsageEvent(date: date, providerKind: provider.kind.rawValue, providerName: provider.name,
                          model: provider.model, kind: kind, usage: nil, success: true, cacheHit: true))
    }

    /// Daily totals on or after `since` (local days).
    static func records(since: Date) async -> [UsageRecord] {
        guard let store = await store.value else { return [] }
        return await store.records(since: since)
    }

    static func removeAll() async {
        guard let store = await store.value else { return }
        await store.removeAll()
        await notify()
    }

    private static func submit(_ event: UsageEvent) {
        Task.detached(priority: .utility) {
            guard let store = await store.value else { return }
            await store.add(event)
            await notify()
        }
    }

    @MainActor
    private static func notify() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
