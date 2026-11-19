import Foundation
import SwiftData

/// Token totals for one local day, provider, model and request kind. Holds numbers only — never source or
/// translated text — and stays small because every request on the same day lands in the same row.
@Model
public final class UsageDay {
    /// "yyyy-MM-dd|providerKind|providerName|model|kind" in the local time zone.
    @Attribute(.unique) public var key: String
    /// Local start of day.
    public var day: Date
    public var providerKind: String
    public var providerName: String
    public var model: String
    public var kind: String
    /// Every request sent, finished or not.
    public var requests: Int
    /// Requests that failed or were cancelled.
    public var incomplete: Int
    /// Results served from a local cache without calling the provider.
    public var cacheHits: Int
    /// Token counts reported by the provider.
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    /// Requests the provider reported no counts for, and their locally estimated tokens (kept apart from the
    /// reported ones above so the UI can label them as estimates).
    public var estimatedRequests: Int
    public var estimatedInputTokens: Int
    public var estimatedOutputTokens: Int

    public init(key: String, day: Date, providerKind: String, providerName: String, model: String, kind: String) {
        self.key = key
        self.day = day
        self.providerKind = providerKind
        self.providerName = providerName
        self.model = model
        self.kind = kind
        self.requests = 0
        self.incomplete = 0
        self.cacheHits = 0
        self.inputTokens = 0
        self.outputTokens = 0
        self.cachedInputTokens = 0
        self.estimatedRequests = 0
        self.estimatedInputTokens = 0
        self.estimatedOutputTokens = 0
    }
}

/// A plain copy of a `UsageDay` row that can leave the store's actor.
public struct UsageRecord: Sendable, Hashable {
    public var day: Date
    public var providerKind: String
    public var providerName: String
    public var model: String
    public var kind: String
    public var requests: Int
    public var incomplete: Int
    public var cacheHits: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public var estimatedRequests: Int = 0
    public var estimatedInputTokens: Int = 0
    public var estimatedOutputTokens: Int = 0

    /// Reported plus estimated; check `hasEstimate` before presenting it as exact.
    public var allInputTokens: Int { inputTokens + estimatedInputTokens }
    public var allOutputTokens: Int { outputTokens + estimatedOutputTokens }
    public var totalTokens: Int { allInputTokens + allOutputTokens }
    public var hasEstimate: Bool { estimatedInputTokens + estimatedOutputTokens > 0 }
    public var usageKind: UsageKind { UsageKind(rawValue: kind) ?? .other }
    public var provider: ProviderKind? { ProviderKind(rawValue: providerKind) }

    public init(day: Date, providerKind: String, providerName: String, model: String, kind: String, requests: Int, incomplete: Int, cacheHits: Int, inputTokens: Int, outputTokens: Int, cachedInputTokens: Int, estimatedRequests: Int = 0, estimatedInputTokens: Int = 0, estimatedOutputTokens: Int = 0) {
        self.day = day
        self.providerKind = providerKind
        self.providerName = providerName
        self.model = model
        self.kind = kind
        self.requests = requests
        self.incomplete = incomplete
        self.cacheHits = cacheHits
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.estimatedRequests = estimatedRequests
        self.estimatedInputTokens = estimatedInputTokens
        self.estimatedOutputTokens = estimatedOutputTokens
    }
}

// MARK: - Schema versions
//
// Same rules as the vocabulary store: every change to `UsageDay` gets a frozen copy of the old model in a new
// `UsageSchemaV<n>` and a migration stage, so an update never leaves the usage store unreadable.

public enum UsageSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] { [UsageDay.self] }
}

public enum UsageMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [UsageSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

/// Owns the usage store (separate from the vocabulary) and does all reads and writes off the main thread.
@ModelActor
public actor UsageStore {
    /// Returns nil when the store cannot be opened; usage tracking is optional, so the app keeps working.
    public static func makeContainer() -> ModelContainer? {
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
                let dir = SharedStorage.directory
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                configuration = ModelConfiguration(url: dir.appending(path: "Usage.store"))
            }
            return try ModelContainer(for: Schema(versionedSchema: UsageSchemaV1.self),
                                      migrationPlan: UsageMigrationPlan.self,
                                      configurations: configuration)
        } catch {
            NSLog("SwipeSay: cannot open usage store: \(error)")
            return nil
        }
    }

    public func add(_ event: UsageEvent) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: event.date)
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let key = [dayKey, event.providerKind, event.providerName, event.model, event.kind.rawValue].joined(separator: "|")

        let row: UsageDay
        if let existing = fetch(key) {
            row = existing
        } else {
            row = UsageDay(key: key, day: day, providerKind: event.providerKind, providerName: event.providerName,
                           model: event.model, kind: event.kind.rawValue)
            modelContext.insert(row)
        }
        if event.cacheHit {
            row.cacheHits += 1
        } else {
            row.requests += 1
            if !event.success { row.incomplete += 1 }
            if let usage = event.usage {
                row.inputTokens += usage.input
                row.outputTokens += usage.output
                row.cachedInputTokens += usage.cachedInput
            } else if let estimate = event.estimated {
                row.estimatedRequests += 1
                row.estimatedInputTokens += estimate.input
                row.estimatedOutputTokens += estimate.output
            }
        }
        try? modelContext.save()
    }

    public func records(since: Date) -> [UsageRecord] {
        let descriptor = FetchDescriptor<UsageDay>(predicate: #Predicate { $0.day >= since },
                                                   sortBy: [SortDescriptor(\.day)])
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.map {
            UsageRecord(day: $0.day, providerKind: $0.providerKind, providerName: $0.providerName, model: $0.model,
                        kind: $0.kind, requests: $0.requests, incomplete: $0.incomplete, cacheHits: $0.cacheHits,
                        inputTokens: $0.inputTokens, outputTokens: $0.outputTokens,
                        cachedInputTokens: $0.cachedInputTokens, estimatedRequests: $0.estimatedRequests,
                        estimatedInputTokens: $0.estimatedInputTokens, estimatedOutputTokens: $0.estimatedOutputTokens)
        }
    }

    public func removeAll() {
        try? modelContext.delete(model: UsageDay.self)
        try? modelContext.save()
    }

    private func fetch(_ key: String) -> UsageDay? {
        var descriptor = FetchDescriptor<UsageDay>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    #if DEBUG
    /// Mock mode only: fills the in-memory store with a month of made-up history so the page has something to show.
    public func seedDemoData() {
        let samples: [(ProviderKind, String, String, Int)] = [
            (.openAI, "OpenAI", "gpt-6-luna", 40),
            (.anthropic, "Anthropic", "claude-haiku-5-5", 18),
            (.gemini, "Google Gemini", "gemini-3.5-flash-lite", 6),
            (.chatGPT, "ChatGPT 订阅", "gpt-6-luna", 10),
            (.openAICompatible, "本地模型", "qwen3:8b", 5), // reports no usage: estimated
        ]
        let kinds: [(UsageKind, Int, Int)] = [(.translate, 450, 120), (.word, 380, 160), (.keyItems, 700, 260), (.analysis, 800, 520)]
        let calendar = Calendar.current
        for offset in 0...30 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let day = calendar.startOfDay(for: date)
            for (provider, name, model, perDay) in samples {
                for (kind, input, output) in kinds {
                    let count = Int.random(in: 0...max(1, perDay / (kind == .translate ? 1 : 3)))
                    guard count > 0 else { continue }
                    let row = UsageDay(key: "demo|\(offset)|\(provider.rawValue)|\(model)|\(kind.rawValue)", day: day,
                                       providerKind: provider.rawValue, providerName: name, model: model,
                                       kind: kind.rawValue)
                    row.requests = count
                    let inputTokens = count * (input + Int.random(in: 0...200))
                    let outputTokens = count * (output + Int.random(in: 0...120))
                    if provider == .openAICompatible {
                        row.estimatedRequests = count
                        row.estimatedInputTokens = inputTokens
                        row.estimatedOutputTokens = outputTokens
                    } else {
                        row.inputTokens = inputTokens
                        row.outputTokens = outputTokens
                        row.cachedInputTokens = count / 2 * 256
                    }
                    modelContext.insert(row)
                }
            }
        }
        try? modelContext.save()
    }
    #endif
}
