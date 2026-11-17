import Foundation
import AppKit

/// Text captured from the screen plus whatever context could be gathered around it.
struct CapturedText {
    enum Origin { case selection, screenshot, manual }

    var text: String
    var context: String?
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var origin: Origin
    /// Screen point (AppKit coordinates) near which to show the popup.
    var anchor: NSPoint?

    var hasUsefulContext: Bool {
        guard let context else { return false }
        let c = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.count > text.trimmingCharacters(in: .whitespacesAndNewlines).count + 12
    }
}

/// Dictionary-style result for a single word / short phrase.
struct WordResult: Decodable, Equatable {
    struct Sense: Decodable, Equatable, Hashable {
        var pos: String?
        var meaning: String?
    }
    struct Example: Decodable, Equatable {
        var source: String?
        var target: String?
    }

    var term: String?
    var lemma: String?
    var phonetic: String?
    var contextMeaning: String?
    var senses: [Sense]?
    var example: Example?
    var note: String?

    enum CodingKeys: String, CodingKey {
        case term, lemma, phonetic, senses, example, note
        case contextMeaning = "context_meaning"
    }
}

/// A learnable expression pulled out of a sentence.
struct KeyItem: Decodable, Equatable, Hashable, Identifiable {
    var text: String
    var kind: String?
    var phonetic: String?
    var meaning: String?
    var note: String?

    var id: String { text.lowercased() }

    var kindLabel: String {
        switch (kind ?? "").lowercased() {
        case "word": return "词"
        case "phrase", "phrasal_verb": return "词组"
        case "idiom": return "习语"
        case "collocation": return "搭配"
        case "pattern": return "句型"
        case "slang": return "口语"
        default: return "表达"
        }
    }
}

struct KeyItemsResult: Decodable, Equatable {
    var items: [KeyItem]?
    var analysisWorthy: Bool?
    var analysisHint: String?

    enum CodingKeys: String, CodingKey {
        case items
        case analysisWorthy = "analysis_worthy"
        case analysisHint = "analysis_hint"
    }
}

struct SentenceAnalysis: Decodable, Equatable {
    struct Chunk: Decodable, Equatable, Hashable {
        var text: String?
        var role: String?
        var explain: String?
    }

    var kind: String?
    var skeleton: String?
    var skeletonTranslation: String?
    var chunks: [Chunk]?
    var insights: [String]?
    var usage: String?
    var paraphrase: String?

    enum CodingKeys: String, CodingKey {
        case kind, skeleton, chunks, insights, usage, paraphrase
        case skeletonTranslation = "skeleton_translation"
    }
}

enum JSONExtractor {
    /// Decodes the first JSON object found in model output (tolerates code fences / chatter).
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end {
            s = String(s[start...end])
        }
        guard let data = s.data(using: .utf8) else { throw LLMError.invalidResponse("empty") }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LLMError.invalidResponse(String(text.prefix(160)))
        }
    }
}
