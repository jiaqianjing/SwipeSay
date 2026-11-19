import Foundation
import CoreGraphics

/// Text captured from the screen plus whatever context could be gathered around it.
public struct CapturedText {
    public enum Origin { case selection, screenshot, manual }

    public var text: String
    public var context: String?
    public var appName: String?
    public var bundleID: String?
    public var windowTitle: String?
    public var origin: Origin
    /// Screen point (AppKit coordinates) near which to show the popup.
    public var anchor: CGPoint?

    public var hasUsefulContext: Bool {
        guard let context else { return false }
        let c = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.count > text.trimmingCharacters(in: .whitespacesAndNewlines).count + 12
    }

    public init(text: String, context: String? = nil, appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil, origin: Origin, anchor: CGPoint? = nil) {
        self.text = text
        self.context = context
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.origin = origin
        self.anchor = anchor
    }
}

/// Dictionary-style result for a single word / short phrase.
public struct WordResult: Codable, Equatable {
    public struct Sense: Codable, Equatable, Hashable {
        public var pos: String?
        public var meaning: String?

        public init(pos: String? = nil, meaning: String? = nil) {
            self.pos = pos
            self.meaning = meaning
        }
    }
    public struct Example: Codable, Equatable {
        public var source: String?
        public var target: String?

        public init(source: String? = nil, target: String? = nil) {
            self.source = source
            self.target = target
        }
    }

    /// How the word inflects (declension, conjugation, gender…), for languages where that matters more than
    /// an English-style part of speech.
    public struct Forms: Codable, Equatable {
        public struct Table: Codable, Equatable, Hashable {
            public struct Row: Codable, Equatable, Hashable {
                public var label: String?
                public var cells: [String]?

                public init(label: String? = nil, cells: [String]? = nil) {
                    self.label = label
                    self.cells = cells
                }
            }
            public var title: String?
            public var columns: [String]?
            public var rows: [Row]?

            public init(title: String? = nil, columns: [String]? = nil, rows: [Row]? = nil) {
                self.title = title
                self.columns = columns
                self.rows = rows
            }
        }
        public var summary: String?
        public var tables: [Table]?

        /// Tables that actually have something in them.
        public var visibleTables: [Table] {
            (tables ?? []).filter { !($0.rows ?? []).isEmpty }
        }
        public var isEmpty: Bool { (summary ?? "").isEmpty && visibleTables.isEmpty }

        public init(summary: String? = nil, tables: [Table]? = nil) {
            self.summary = summary
            self.tables = tables
        }
    }

    public var term: String?
    public var lemma: String?
    public var phonetic: String?
    public var lemmaPhonetic: String?
    public var contextMeaning: String?
    public var senses: [Sense]?
    public var example: Example?
    public var note: String?
    public var forms: Forms?

    public enum CodingKeys: String, CodingKey {
        case term, lemma, phonetic, senses, example, note, forms
        case lemmaPhonetic = "lemma_phonetic"
        case contextMeaning = "context_meaning"
    }

    public init(term: String? = nil, lemma: String? = nil, phonetic: String? = nil, lemmaPhonetic: String? = nil, contextMeaning: String? = nil, senses: [Sense]? = nil, example: Example? = nil, note: String? = nil, forms: Forms? = nil) {
        self.term = term
        self.lemma = lemma
        self.phonetic = phonetic
        self.lemmaPhonetic = lemmaPhonetic
        self.contextMeaning = contextMeaning
        self.senses = senses
        self.example = example
        self.note = note
        self.forms = forms
    }
}

public enum Phonetic {
    /// True when `phonetic` is just `term` with stress / accent marks added (e.g. Russian "молоко́" for "молоко").
    /// Such a reading replaces the headword instead of being shown next to it.
    public static func isMarkedSpelling(_ phonetic: String, of term: String) -> Bool {
        guard !phonetic.isEmpty, phonetic != term else { return false }
        return stripMarks(phonetic).lowercased() == stripMarks(term).lowercased()
    }

    /// Removes combining marks except the ones that are part of ordinary spelling (ё, й stay intact).
    public static func stripMarks(_ s: String) -> String {
        let decomposed = s.decomposedStringWithCanonicalMapping
        let stripped = String(String.UnicodeScalarView(decomposed.unicodeScalars.filter {
            $0.value != 0x0301 && $0.value != 0x0300
        }))
        return stripped.precomposedStringWithCanonicalMapping
    }
}

/// A learnable expression pulled out of a sentence.
public struct KeyItem: Codable, Equatable, Hashable, Identifiable {
    public var text: String
    public var kind: String?
    public var phonetic: String?
    public var meaning: String?
    public var note: String?

    public var id: String { text.lowercased() }

    public var kindLabel: String {
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

    public init(text: String, kind: String? = nil, phonetic: String? = nil, meaning: String? = nil, note: String? = nil) {
        self.text = text
        self.kind = kind
        self.phonetic = phonetic
        self.meaning = meaning
        self.note = note
    }
}

public struct KeyItemsResult: Decodable, Equatable {
    public var items: [KeyItem]?
    public var analysisWorthy: Bool?
    public var analysisHint: String?

    public enum CodingKeys: String, CodingKey {
        case items
        case analysisWorthy = "analysis_worthy"
        case analysisHint = "analysis_hint"
    }

    public init(items: [KeyItem]? = nil, analysisWorthy: Bool? = nil, analysisHint: String? = nil) {
        self.items = items
        self.analysisWorthy = analysisWorthy
        self.analysisHint = analysisHint
    }
}

public struct SentenceAnalysis: Decodable, Equatable {
    public struct Chunk: Decodable, Equatable, Hashable {
        public var text: String?
        public var role: String?
        public var explain: String?

        public init(text: String? = nil, role: String? = nil, explain: String? = nil) {
            self.text = text
            self.role = role
            self.explain = explain
        }
    }

    public var kind: String?
    public var skeleton: String?
    public var skeletonTranslation: String?
    public var chunks: [Chunk]?
    public var insights: [String]?
    public var usage: String?
    public var paraphrase: String?

    public enum CodingKeys: String, CodingKey {
        case kind, skeleton, chunks, insights, usage, paraphrase
        case skeletonTranslation = "skeleton_translation"
    }

    public init(kind: String? = nil, skeleton: String? = nil, skeletonTranslation: String? = nil, chunks: [Chunk]? = nil, insights: [String]? = nil, usage: String? = nil, paraphrase: String? = nil) {
        self.kind = kind
        self.skeleton = skeleton
        self.skeletonTranslation = skeletonTranslation
        self.chunks = chunks
        self.insights = insights
        self.usage = usage
        self.paraphrase = paraphrase
    }
}

public enum JSONExtractor {
    /// Decodes the first JSON object found in model output (tolerates code fences / chatter).
    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
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
