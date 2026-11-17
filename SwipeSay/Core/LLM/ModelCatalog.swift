import Foundation

/// One entry from a provider's list-models endpoint, with whatever metadata the provider reports.
struct ModelInfo: Hashable {
    var id: String
    /// Release time: OpenAI `created` (Unix seconds), Anthropic `created_at`. nil when the provider doesn't say.
    var created: Date?
    /// Gemini `supportedGenerationMethods`. nil when the provider doesn't report capabilities.
    var generationMethods: [String]?
    /// Flagged by the provider (Anthropic `lifecycle == "deprecated"`, OpenAI `shutdown_date` set) or listed in
    /// `ModelCatalog.knownDeprecated`. `ModelCatalog.arrange` sets it for both.
    var deprecated = false
}

/// Turns a raw model listing into what the model picker shows: chat models only, no dated snapshots
/// or deprecated models, newest first, with the current and recommended models on top.
/// Rules are deliberately name-agnostic (no "latest three generations" parsing), so new model names keep working.
enum ModelCatalog {
    struct Arranged: Equatable {
        /// The selected model, then the provider's suggested models, as far as the listing contains them.
        var pinned: [ModelInfo]
        /// Everything else that passed the filters, newest first.
        var others: [ModelInfo]
        /// Number of distinct models in the listing before filtering.
        var total: Int
        /// The selected model is deprecated, so the user should switch.
        var selectedDeprecated: Bool

        var count: Int { pinned.count + others.count }
        var hidden: Int { total - count }
    }

    /// Filters and sorts `models` for `kind`. Deprecated models are always removed; `showAll` skips the
    /// other filters but keeps the ordering. The selected model is never removed, so it can be shown as deprecated.
    static func arrange(_ models: [ModelInfo], kind: ProviderKind, selected: String, showAll: Bool = false) -> Arranged {
        var seen = Set<String>()
        let unique = models.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }.map { m -> ModelInfo in
            var m = m
            m.deprecated = m.deprecated || isKnownDeprecated(m.id, kind: kind)
            return m
        }

        let current = unique.filter { !$0.deprecated }
        let visible: [ModelInfo]
        if showAll {
            visible = unique.filter { $0.id == selected || !$0.deprecated }
        } else {
            let usable = current.filter { isChatModel($0, kind: kind) }
            let snapshots = hiddenSnapshots(usable)
            visible = unique.filter { $0.id == selected || (usable.contains($0) && !snapshots.contains($0.id)) }
        }

        // ChatGPT's list comes in the backend's priority order: pin only the current model and keep the rest as is.
        var pinnedIDs: [String] = []
        let candidates = kind == .chatGPT ? [selected] : [selected] + kind.suggestedModels
        for id in candidates where !id.isEmpty && !pinnedIDs.contains(id) { pinnedIDs.append(id) }
        let pinned = pinnedIDs.compactMap { id in visible.first { $0.id == id } }
        let rest = visible.filter { !pinnedIDs.contains($0.id) }
        let selectedDeprecated = unique.first { $0.id == selected }?.deprecated ?? isKnownDeprecated(selected, kind: kind)
        return Arranged(pinned: pinned, others: newestFirst(rest, kind: kind), total: unique.count,
                        selectedDeprecated: selectedDeprecated)
    }

    // MARK: Deprecation

    /// Gemini's Model resource has no deprecation field, so its deprecated and shut-down ids are listed here.
    /// Source: https://aistudio.google.com/docs/models, checked 2026-11-17 (2.5 Pro / Flash reroute on 2026-12-01,
    /// 2.5 Flash Image shuts down 2027-03-15, Omni 1.1 Flash reroutes 2026-12-03, the rest are shut down).
    private static let knownDeprecated: [ProviderKind: Set<String>] = [
        .gemini: [
            "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-image", "gemini-omni-1.1-flash",
            "gemini-2.0-flash", "gemini-2.0-flash-lite", "gemini-3-pro-preview", "gemini-3.1-flash-lite-preview",
            "gemini-robotics-er-1.6-preview", "gemini-2.5-computer-use-preview-10-2025",
        ],
    ]

    /// Listed above, or a dated snapshot of a listed model ("gemini-2.0-flash-001", "gemini-2.5-flash-preview-09-2025").
    static func isKnownDeprecated(_ id: String, kind: ProviderKind) -> Bool {
        guard let list = knownDeprecated[kind] else { return false }
        var id = id.trimmingCharacters(in: .whitespaces).lowercased()
        if id.hasPrefix("models/") { id.removeFirst(7) }
        return list.contains(id) || snapshotStamp(id)?.aliases.contains(where: list.contains) == true
    }

    // MARK: Purpose filter

    /// Substrings that mark a model as something other than chat text generation.
    private static let nonChatSubstrings = [
        "embedding", "whisper", "transcribe", "audio", "realtime", "moderation",
        "image", "dall-e", "imagen", "sora", "search", "computer-use",
    ]
    /// Whole name tokens (split on anything but letters and digits) with the same meaning.
    private static let nonChatTokens: Set<String> = ["embed", "tts", "veo"]

    /// Whether a model can be used for chat/translation. OpenAI-compatible servers name models too freely
    /// (OpenRouter, Ollama, LM Studio …), so nothing is filtered there to avoid dropping usable models.
    static func isChatModel(_ model: ModelInfo, kind: ProviderKind) -> Bool {
        let id = model.id.lowercased()
        var substrings = nonChatSubstrings
        var tokens = nonChatTokens
        switch kind {
        case .openAICompatible, .chatGPT:
            return true
        case .gemini:
            if let methods = model.generationMethods, !methods.contains("generateContent") { return false }
            // TTS, image and Live models also answer generateContent, but don't return text for a chat prompt.
            tokens.formUnion(["live", "aqa"])
        case .openAI:
            // Available through the Responses or Completions API only, not /chat/completions which we call.
            substrings += ["codex", "deep-research", "instruct", "babbage", "davinci"]
            tokens.insert("pro")
        case .anthropic, .deepSeek:
            break
        }
        if substrings.contains(where: { id.contains($0) }) { return false }
        let parts = id.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return !parts.contains(where: tokens.contains)
    }

    // MARK: Dated snapshots

    /// Date or version stamps that pin a snapshot of an alias, most specific first.
    /// Each regex's first capture group is the sortable stamp; the whole match is removed to get the alias.
    private static let stampPatterns: [(regex: NSRegularExpression, key: (String) -> Int?)] = [
        // gpt-5-2025-08-07, gpt-4o-realtime-preview-2024-12-17
        stamp(#"-(20\d{2}-\d{2}-\d{2})(?=-|$)"#) { Int($0.replacingOccurrences(of: "-", with: "")) },
        // claude-sonnet-4-5-20250929
        stamp(#"-(20\d{6})(?=-|$)"#) { Int($0) },
        // gemini-2.5-flash-preview-09-2025 (MM-YYYY)
        stamp(#"-(\d{2}-20\d{2})$"#) { s in
            let p = s.split(separator: "-")
            return Int(p[1] + p[0]).map { $0 * 100 }
        },
        // gemini-2.5-flash-preview-05-20 (MM-DD, year unknown)
        stamp(#"(?<=-preview)-(\d{2}-\d{2})$"#) { Int($0.replacingOccurrences(of: "-", with: "")) },
        // gpt-4-0613, gpt-4-1106-preview (MMDD); mistral-large-2411 (YYMM)
        stamp(#"-(\d{4})(?=-|$)"#) { s in
            guard let a = Int(s.prefix(2)), let b = Int(s.suffix(2)) else { return nil }
            if (1...12).contains(a), (1...31).contains(b) { return a * 100 + b }
            if (23...39).contains(a), (1...12).contains(b) { return (2000 + a) * 10_000 + b * 100 }
            return nil
        },
        // gemini-2.0-flash-001
        stamp(#"(?<=[a-z])-(\d{3})$"#) { Int($0) },
    ]

    private static func stamp(_ pattern: String, _ key: @escaping (String) -> Int?)
        -> (regex: NSRegularExpression, key: (String) -> Int?) {
        // Patterns are literals above, so a failure here is a programming error.
        (try! NSRegularExpression(pattern: pattern), key)
    }

    /// Splits a snapshot id into the alias ids it pins and a sortable stamp, e.g.
    /// "gpt-5-2025-08-07" → (["gpt-5"], 20250807). nil when the id has no stamp.
    static func snapshotStamp(_ id: String) -> (aliases: [String], key: Int)? {
        let lower = id.lowercased()
        for pattern in stampPatterns {
            guard let match = pattern.regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let whole = Range(match.range, in: lower), let stamp = Range(match.range(at: 1), in: lower),
                  let key = pattern.key(String(lower[stamp])) else { continue }
            let alias = lower.replacingCharacters(in: whole, with: "")
            var aliases = [alias, alias + "-latest"]
            // A dated preview also stands in for the released model ("gemini-2.5-flash-preview-05-20" → "gemini-2.5-flash").
            if alias.hasSuffix("-preview") { aliases.append(String(alias.dropLast("-preview".count))) }
            return (aliases, key)
        }
        return nil
    }

    /// Ids of snapshots to hide: every snapshot whose alias is also listed, and, where no alias is listed
    /// (Anthropic lists dated ids only), all but the newest snapshot of that alias.
    static func hiddenSnapshots(_ models: [ModelInfo]) -> Set<String> {
        let ids = Set(models.map { $0.id.lowercased() })
        var hidden = Set<String>()
        var orphans: [String: [(model: ModelInfo, key: Int)]] = [:]
        for model in models {
            guard let stamp = snapshotStamp(model.id) else { continue }
            if stamp.aliases.contains(where: ids.contains) {
                hidden.insert(model.id)
            } else {
                orphans[stamp.aliases[0], default: []].append((model, stamp.key))
            }
        }
        for group in orphans.values where group.count > 1 {
            let newest = group.max { a, b in
                (a.model.created ?? .distantPast, a.key) < (b.model.created ?? .distantPast, b.key)
            }
            for entry in group where entry.model.id != newest?.model.id { hidden.insert(entry.model.id) }
        }
        return hidden
    }

    // MARK: Ordering

    /// Newest first by release date. Models without one follow: compatible servers alphabetically (their
    /// names are too free-form to compare), others by the first version number in the name, descending,
    /// keeping the provider's order between equal versions. ChatGPT keeps the server's order untouched.
    static func newestFirst(_ models: [ModelInfo], kind: ProviderKind) -> [ModelInfo] {
        if kind == .chatGPT { return models }
        let indexed = Array(models.enumerated())
        return indexed.sorted { a, b in
            switch (a.element.created, b.element.created) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                if kind == .openAICompatible {
                    return a.element.id.localizedStandardCompare(b.element.id) == .orderedAscending
                }
                let va = version(a.element.id), vb = version(b.element.id)
                if va != vb { return va.lexicographicallyPrecedes(vb) == false }
            default: break
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// First dotted number in a name: "gemini-2.5-flash" → [2, 5]. Empty when there is none.
    static func version(_ id: String) -> [Int] {
        guard let range = id.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return [] }
        return id[range].split(separator: ".").compactMap { Int($0) }
    }

    // MARK: Reference prices

    /// Date the price table below was checked against the official pricing pages.
    static let pricesCheckedOn = "2026-11-17"

    /// USD per million tokens, standard (non-batch, non-priority) tier. Only for the suggested models;
    /// anything else shows no price rather than a stale one. Sources, fetched 2026-11-17:
    /// - OpenAI: https://developers.openai.com/api/docs/pricing (Standard, short context ≤ 272K input tokens)
    /// - Anthropic: https://platform.claude.com/docs/en/about-claude/pricing (cached = cache hits)
    /// - Gemini: https://ai.google.dev/gemini-api/docs/pricing, now https://aistudio.google.com/docs/pricing
    ///   (paid tier, text input). gemini-3.8-flash is left out: its price doubles on 2027-01-01.
    /// DeepSeek is left out: https://api-docs.deepseek.com/quick_start/pricing bills by peak / off-peak hours.
    /// ChatGPT uses the subscription, so it has no per-token price.
    private static let prices: [ProviderKind: [String: ModelPrice]] = [
        .openAI: [
            "gpt-6-luna": ModelPrice(input: 0.10, cachedInput: 0.01, output: 0.50,
                                     longContext: (272_000, .init(input: 0.20, cachedInput: 0.02, output: 0.75))),
            "gpt-6.1-terra": ModelPrice(input: 1.00, cachedInput: 0.05, output: 5.00,
                                        longContext: (272_000, .init(input: 2.00, cachedInput: 0.10, output: 7.50))),
            "gpt-6.1-sol": ModelPrice(input: 2.00, cachedInput: 0.10, output: 10.00,
                                      longContext: (272_000, .init(input: 4.00, cachedInput: 0.20, output: 15.00))),
            "gpt-5.4-mini": ModelPrice(input: 0.75, cachedInput: 0.075, output: 4.50),
        ],
        .anthropic: [
            "claude-haiku-5-5": ModelPrice(input: 0.10, cachedInput: 0.01, output: 0.50,
                                           longContext: (100_000, .init(input: 0.50, cachedInput: 0.05, output: 2.50))),
            "claude-sonnet-5-5": ModelPrice(input: 2, cachedInput: 0.10, output: 10),
            "claude-opus-5-5": ModelPrice(input: 4, cachedInput: 0.20, output: 20),
            "claude-fable-5-2": ModelPrice(input: 8, cachedInput: 0.20, output: 40),
        ],
        .gemini: [
            "gemini-3.5-flash-lite": ModelPrice(input: 0.30, cachedInput: 0.03, output: 2.50),
            "gemini-3.1-flash-lite": ModelPrice(input: 0.25, cachedInput: 0.025, output: 1.50),
            "gemini-4-hydrogen": ModelPrice(input: 1.50, cachedInput: 0.075, output: 7.50),
        ],
    ]

    static func price(for model: String, kind: ProviderKind) -> ModelPrice? {
        prices[kind]?[model.trimmingCharacters(in: .whitespaces)]
    }
}

/// Reference per-token price, USD per million tokens. Some models charge more once the prompt is long.
struct ModelPrice: Equatable {
    struct Rates: Equatable {
        var input: Double
        var cachedInput: Double?
        var output: Double
    }

    var base: Rates
    /// Prompts longer than this many input tokens are billed at `longContext` rates.
    var longContextThreshold: Int?
    var longContext: Rates?

    init(input: Double, cachedInput: Double?, output: Double, longContext: (threshold: Int, rates: Rates)? = nil) {
        base = Rates(input: input, cachedInput: cachedInput, output: output)
        longContextThreshold = longContext?.threshold
        self.longContext = longContext?.rates
    }

    func rates(promptTokens: Int) -> Rates {
        if let threshold = longContextThreshold, let long = longContext, promptTokens > threshold { return long }
        return base
    }

    /// "$0.10 / $0.50": input / output at base rates.
    var label: String { "\(Self.format(base.input)) / \(Self.format(base.output))" }

    private static func format(_ usd: Double) -> String {
        // Two decimals, or three when that's what the price has ($0.075).
        let cents = (usd * 100).rounded()
        return abs(usd * 100 - cents) < 1e-9 ? String(format: "$%.2f", usd) : String(format: "$%.3f", usd)
    }
}
