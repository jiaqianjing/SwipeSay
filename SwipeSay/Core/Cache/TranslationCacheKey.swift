import Foundation
import CryptoKit

/// Identifies one cached model result. The digest is a SHA-256 over every input that changes the prompt in a way
/// that matters, so a different language, model, learner level or prompt version simply misses the cache.
struct TranslationCacheKey: Hashable {
    enum Kind: String, CaseIterable {
        case sentence, word, keyItems, analysis
    }

    let kind: Kind
    let digest: String

    /// Fields are hashed in the given order. Each value is length-prefixed, so no choice of text can make two
    /// different field lists serialize to the same bytes. `nil` and empty values are treated the same.
    init(kind: Kind, fields: [(String, String?)]) {
        self.kind = kind
        var material = "kind:\(kind.rawValue)\nprompts:\(Prompts.version)\n"
        for (name, value) in fields {
            let v = value ?? ""
            material += "\(name):\(v.utf8.count):\(v)\n"
        }
        digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Per-kind keys
    //
    // Context (the surrounding paragraph) is only part of the WORD key: the card explains the meaning in this
    // context, so a different paragraph can legitimately need a different answer. Sentence translations, key
    // items and analyses are driven by the sentence itself; leaving context out lets the same sentence hit the
    // cache wherever it appears. App name and window title are weak prompt hints and are never part of a key.

    static func sentence(text: String, target: AppLanguage, model: String) -> Self {
        Self(kind: .sentence, fields: [
            ("text", normalize(text)),
            ("target", target.rawValue),
            ("model", normalizeModel(model)),
        ])
    }

    static func word(text: String, context: String?, target: AppLanguage, native: AppLanguage, model: String) -> Self {
        Self(kind: .word, fields: [
            ("text", normalize(text)),
            ("context", context.map(normalize)),
            ("target", target.rawValue),
            ("native", native.rawValue),
            ("model", normalizeModel(model)),
        ])
    }

    /// `translation` is part of the prompt (and, when the selection is in the user's own language, the sentence
    /// being studied), so it is keyed verbatim. A cached translation reproduces it exactly, so the chain still hits.
    static func keyItems(sentence: String, translation: String, native: AppLanguage, level: LearnerLevel,
                         model: String) -> Self {
        Self(kind: .keyItems, fields: [
            ("sentence", normalize(sentence)),
            ("translation", normalize(translation)),
            ("native", native.rawValue),
            ("level", level.rawValue),
            ("model", normalizeModel(model)),
        ])
    }

    /// The hint comes from the (cached) key items and steers what the analysis focuses on.
    static func analysis(sentence: String, translation: String, hint: String?, native: AppLanguage,
                         level: LearnerLevel, model: String) -> Self {
        Self(kind: .analysis, fields: [
            ("sentence", normalize(sentence)),
            ("translation", normalize(translation)),
            ("hint", hint.map(normalize)),
            ("native", native.rawValue),
            ("level", level.rawValue),
            ("model", normalizeModel(model)),
        ])
    }

    // MARK: Normalization

    /// Makes selections that differ only in invisible ways share a key: Unicode composition, line-ending style,
    /// runs of spaces/tabs, leading/trailing whitespace on each line and repeated blank lines. Case and
    /// punctuation are kept because they can change the meaning ("US" vs "us").
    static func normalize(_ text: String) -> String {
        let unified = text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for rawLine in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            // Keep at most one blank line between paragraphs.
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    static func normalizeModel(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Helpers shared by the store and the UI

enum TranslationCachePolicy {
    /// Ceiling on the estimated size of all entries, whatever limit the user picked (or a hand-edited preference).
    static let hardMaxBytes = 5 * 1024 * 1024 * 1024

    /// The user's limit, clamped to `0...hardMaxBytes`.
    static func effectiveLimit(_ bytes: Int) -> Int {
        min(max(bytes, 0), hardMaxBytes)
    }

    /// Eviction trims to 90 % of the limit, so a full cache does not evict again on every single write.
    static func evictionTarget(forLimit limit: Int) -> Int {
        limit / 10 * 9
    }

    /// Rough per-row overhead (key, dates, SQLite bookkeeping) added to the text sizes.
    static let rowOverhead = 160

    static func estimatedBytes(source: String, payload: String) -> Int {
        source.utf8.count + payload.utf8.count + rowOverhead
    }

    /// Given entry sizes ordered least recently used first, returns how many leading entries to delete so the
    /// running total drops to `target` or below. Returns 0 when the total is already within `target`.
    static func evictionCount(oldestFirst sizes: [Int], total: Int, target: Int) -> Int {
        var remaining = total
        var count = 0
        for size in sizes where remaining > target {
            remaining -= size
            count += 1
        }
        return count
    }

    /// "刚刚", "5 分钟前", "3 天前" … — fixed Chinese wording regardless of the system locale, to match the UI.
    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "刚刚"
        case ..<3_600: return "\(seconds / 60) 分钟前"
        case ..<86_400: return "\(seconds / 3_600) 小时前"
        case ..<(30 * 86_400): return "\(seconds / 86_400) 天前"
        case ..<(365 * 86_400): return "\(seconds / (30 * 86_400)) 个月前"
        default: return "\(seconds / (365 * 86_400)) 年前"
        }
    }
}
