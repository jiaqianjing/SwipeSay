import Foundation
import SwiftData
import Combine

@Model
final class VocabItem {
    @Attribute(.unique) var key: String
    var term: String
    var phonetic: String
    var kind: String
    var meaning: String
    var note: String
    var sentence: String
    var sentenceTranslation: String
    var sourceApp: String
    var createdAt: Date
    var reviewCount: Int
    /// 0 = new … 6 = mastered (spaced-repetition stage).
    var stage: Int
    var nextReview: Date

    init(term: String, phonetic: String = "", kind: String = "word", meaning: String, note: String = "",
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

    static func normalize(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }

    var isMastered: Bool { stage >= VocabItem.intervals.count }
    var isDue: Bool { !isMastered && nextReview <= Date() }

    /// Days until next review for each stage.
    static let intervals: [Double] = [0, 1, 2, 4, 7, 15]

    enum Grade { case forgot, fuzzy, known }

    func review(_ grade: Grade) {
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

enum VocabularySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [VocabItem.self] }
}

enum VocabularyMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [VocabularySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Owns the SwiftData container and offers simple upsert helpers.
@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    let container: ModelContainer
    /// Lower-cased keys of saved terms — lets the popup show ★ state cheaply.
    @Published private(set) var savedKeys: Set<String> = []

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
                let dir = URL.applicationSupportDirectory.appending(path: "SwipeSay", directoryHint: .isDirectory)
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

    var context: ModelContext { container.mainContext }

    func reloadKeys() {
        let items = (try? context.fetch(FetchDescriptor<VocabItem>())) ?? []
        savedKeys = Set(items.map(\.key))
    }

    func contains(_ term: String) -> Bool { savedKeys.contains(VocabItem.normalize(term)) }

    @discardableResult
    func add(term: String, phonetic: String?, kind: String, meaning: String, note: String?,
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

    func remove(term: String) {
        guard let item = fetch(VocabItem.normalize(term)) else { return }
        delete(item)
    }

    func delete(_ item: VocabItem) {
        savedKeys.remove(item.key)
        context.delete(item)
        try? context.save()
    }

    func save() { try? context.save() }

    private func fetch(_ key: String) -> VocabItem? {
        var descriptor = FetchDescriptor<VocabItem>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func exportCSV() -> String {
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
