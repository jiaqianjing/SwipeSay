import Foundation
import SwiftData
import Combine

@Model
public final class VocabItem {
    @Attribute(.unique) public var key: String
    public var term: String
    public var phonetic: String
    public var kind: String
    public var meaning: String
    public var note: String
    public var sentence: String
    public var sentenceTranslation: String
    public var sourceApp: String
    public var createdAt: Date
    public var reviewCount: Int
    /// 0 = new … 6 = mastered (spaced-repetition stage).
    public var stage: Int
    public var nextReview: Date

    public init(term: String, phonetic: String = "", kind: String = "word", meaning: String, note: String = "",
         sentence: String = "", sentenceTranslation: String = "", sourceApp: String = "") {
        self.key = VocabItem.normalize(term)
        self.term = term
        self.phonetic = phonetic
        self.kind = kind
        self.meaning = meaning
        self.note = note
        self.sentence = sentence
        self.sentenceTranslation = sentenceTranslation
        self.sourceApp = sourceApp
        self.createdAt = Date()
        self.reviewCount = 0
        self.stage = 0
        self.nextReview = Date()
    }

    public static func normalize(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }

    public var isMastered: Bool { stage >= VocabItem.intervals.count }
    public var isDue: Bool { !isMastered && nextReview <= Date() }

    /// Days until next review for each stage.
    public static let intervals: [Double] = [0, 1, 2, 4, 7, 15]

    public enum Grade { case forgot, fuzzy, known }

    public func review(_ grade: Grade) {
        reviewCount += 1
        switch grade {
        case .forgot: stage = 0
        case .fuzzy: stage = max(1, stage)
        case .known: stage += 1
        }
        let days = stage < VocabItem.intervals.count ? VocabItem.intervals[stage] : 60
        nextReview = Date().addingTimeInterval(max(days, 0.007) * 86_400) // at least ~10 min
    }
}

// MARK: - Schema versions
//
// Every change to a stored model gets a new schema version and a migration stage, so updating the app never
// leaves an existing vocabulary unreadable. To change `VocabItem`:
//   1. Copy the current model into a frozen `VocabularySchemaV<n>` enum (as nested types).
//   2. Edit the live model and add a `VocabularySchemaV<n+1>` that lists it.
//   3. Append the new schema to `schemas` and a `.lightweight` or `.custom` stage to `stages`.

public enum VocabularySchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] { [VocabItem.self] }
}

public enum VocabularyMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [VocabularySchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

/// Owns the SwiftData container and offers simple upsert helpers.
@MainActor
public final class VocabularyStore: ObservableObject {
    public static let shared = VocabularyStore()

    public let container: ModelContainer
    /// Lower-cased keys of saved terms — lets the popup show ★ state cheaply.
    @Published public private(set) var savedKeys: Set<String> = []

    private init() {
        do {
            let configuration: ModelConfiguration
            #if DEBUG
            let inMemory = MockClient.isEnabled
            #else
            let inMemory = false
            #endif
            if inMemory {
                configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            } else {
                // Not sandboxed: use our own folder instead of the shared default.store.
                let dir = SharedStorage.directory
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                configuration = ModelConfiguration(url: dir.appending(path: "Vocabulary.store"))
            }
            container = try ModelContainer(for: Schema(versionedSchema: VocabularySchemaV1.self),
                                           migrationPlan: VocabularyMigrationPlan.self,
                                           configurations: configuration)
        } catch {
            fatalError("SwipeSay: cannot open vocabulary store: \(error)")
        }
        reloadKeys()
    }

    public var context: ModelContext { container.mainContext }

    public func reloadKeys() {
        let items = (try? context.fetch(FetchDescriptor<VocabItem>())) ?? []
        savedKeys = Set(items.map(\.key))
    }

    public func contains(_ term: String) -> Bool { savedKeys.contains(VocabItem.normalize(term)) }

    @discardableResult
    public func add(term: String, phonetic: String?, kind: String, meaning: String, note: String?,
             sentence: String?, sentenceTranslation: String?, sourceApp: String?) -> Bool {
        let key = VocabItem.normalize(term)
        guard !key.isEmpty, !meaning.isEmpty else { return false }
        if let existing = fetch(key) {
            // Keep the original entry but refresh empty fields.
            if existing.phonetic.isEmpty, let phonetic { existing.phonetic = phonetic }
            if existing.sentence.isEmpty, let sentence { existing.sentence = sentence }
            if existing.sentenceTranslation.isEmpty, let sentenceTranslation { existing.sentenceTranslation = sentenceTranslation }
            try? context.save()
            return false
        }
        let item = VocabItem(term: term.trimmingCharacters(in: .whitespacesAndNewlines), phonetic: phonetic ?? "",
                             kind: kind, meaning: meaning, note: note ?? "", sentence: sentence ?? "",
                             sentenceTranslation: sentenceTranslation ?? "", sourceApp: sourceApp ?? "")
        context.insert(item)
        try? context.save()
        savedKeys.insert(key)
        return true
    }

    public func remove(term: String) {
        guard let item = fetch(VocabItem.normalize(term)) else { return }
        delete(item)
    }

    public func delete(_ item: VocabItem) {
        savedKeys.remove(item.key)
        context.delete(item)
        try? context.save()
    }

    public func save() { try? context.save() }

    private func fetch(_ key: String) -> VocabItem? {
        var descriptor = FetchDescriptor<VocabItem>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    public func exportCSV() -> String {
        let items = (try? context.fetch(FetchDescriptor<VocabItem>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = ["term,phonetic,kind,meaning,note,sentence,translation,source,added"]
        let fmt = ISO8601DateFormatter()
        for i in items {
            rows.append([i.term, i.phonetic, i.kind, i.meaning, i.note, i.sentence, i.sentenceTranslation, i.sourceApp,
                         fmt.string(from: i.createdAt)].map(esc).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}

#if DEBUG
extension VocabularyStore {
    /// `-SwipeSayDemoVocabulary YES` (mock mode only) fills the in-memory vocabulary with sample entries.
    public func seedDemo() {
        let samples: [(String, String, String, String, String, String, String)] = [
            ("ubiquitous", "/juːˈbɪkwɪtəs/", "word", "无处不在的", "常与 become 连用；名词形式 ubiquity。",
             "Smartphones have become ubiquitous in modern life.", "智能手机在现代生活中已无处不在。"),
            ("no sooner … than", "", "pattern", "一……就……", "no sooner 置于句首时主谓倒装",
             "No sooner had she set foot in the house than she felt an inexplicable sense of dread.",
             "她刚一踏进那栋房子，就感到一种难以名状的恐惧。"),
            ("set foot in", "", "phrase", "踏入；进入", "",
             "No sooner had she set foot in the house than she felt an inexplicable sense of dread.",
             "她刚一踏进那栋房子，就感到一种难以名状的恐惧。"),
            ("inexplicable", "/ˌɪnɪkˈsplɪkəbl/", "word", "无法解释的", "比 strange 更正式",
             "She felt an inexplicable sense of dread.", "她感到一种难以名状的恐惧。"),
            ("hit the ground running", "", "idiom", "一上手就全力投入", "多用于新工作、新项目的开局",
             "The new team hit the ground running.", "新团队一上来就进入了状态。"),
            ("serendipity", "/ˌserənˈdɪpəti/", "word", "意外发现美好事物的运气", "",
             "Finding this café was pure serendipity.", "发现这家咖啡馆纯属意外之喜。"),
            ("take something with a grain of salt", "", "idiom", "对……半信半疑", "",
             "Take online reviews with a grain of salt.", "网上的评价要有所保留地看。"),
            ("meticulous", "/məˈtɪkjələs/", "word", "一丝不苟的", "褒义，强调对细节的极致关注",
             "She keeps meticulous notes.", "她的笔记做得一丝不苟。"),
        ]
        let apps = ["Safari", "Safari", "Safari", "Safari", "Slack", "Notes", "Chrome", "Mail"]
        for (i, s) in samples.enumerated() {
            add(term: s.0, phonetic: s.1, kind: s.2, meaning: s.3, note: s.4,
                sentence: s.5, sentenceTranslation: s.6, sourceApp: apps[i])
        }
    }
}
#endif
