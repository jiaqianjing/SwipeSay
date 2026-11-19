import Foundation
import CoreGraphics

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
    var anchor: CGPoint?

    var hasUsefulContext: Bool {
        guard let context else { return false }
        let c = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.count > text.trimmingCharacters(in: .whitespacesAndNewlines).count + 12
    }
}

/// Dictionary-style result for a single word / short phrase.
struct WordResult: Codable, Equatable {
    struct Sense: Codable, Equatable, Hashable {
        var pos: String?
        var meaning: String?
    }
    struct Example: Codable, Equatable {
        var source: String?
        var target: String?
    }

    /// How the word inflects (declension, conjugation, gender…), for languages where that matters more than
    /// an English-style part of speech.
    struct Forms: Codable, Equatable {
        struct Table: Codable, Equatable, Hashable {
            struct Row: Codable, Equatable, Hashable {
                var label: String?
                var cells: [String]?
            }
            var title: String?
            var columns: [String]?
            var rows: [Row]?
        }
        var summary: String?
        var tables: [Table]?

        /// Tables that actually have something in them.
        var visibleTables: [Table] {
            (tables ?? []).filter { !($0.rows ?? []).isEmpty }
        }
        var isEmpty: Bool { (summary ?? "").isEmpty && visibleTables.isEmpty }
    }

    var term: String?
    var lemma: String?
    var phonetic: String?
    var lemmaPhonetic: String?
    var contextMeaning: String?
    var senses: [Sense]?
    var example: Example?
    var note: String?
    var forms: Forms?

    enum CodingKeys: String, CodingKey {
        case term, lemma, phonetic, senses, example, note, forms
        case lemmaPhonetic = "lemma_phonetic"
        case contextMeaning = "context_meaning"
    }
}

enum Phonetic {
    /// True when `phonetic` is just `term` with stress / accent marks added (e.g. Russian "молоко́" for "молоко").
    /// Such a reading replaces the headword instead of being shown next to it.
    static func isMarkedSpelling(_ phonetic: String, of term: String) -> Bool {
        guard !phonetic.isEmpty, phonetic != term else { return false }
        return stripMarks(phonetic).lowercased() == stripMarks(term).lowercased()
    }

    /// Removes combining marks except the ones that are part of ordinary spelling (ё, й stay intact).
    static func stripMarks(_ s: String) -> String {
        let decomposed = s.decomposedStringWithCanonicalMapping
        let stripped = String(String.UnicodeScalarView(decomposed.unicodeScalars.filter {
            $0.value != 0x0301 && $0.value != 0x0300
        }))
        return stripped.precomposedStringWithCanonicalMapping
    }
}

/// A learnable expression pulled out of a sentence.
struct KeyItem: Codable, Equatable, Hashable, Identifiable {
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
