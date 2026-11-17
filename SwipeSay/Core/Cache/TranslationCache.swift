import Foundation
import SwiftData
import Combine

@Model
final class CacheEntry {
    /// `TranslationCacheKey.digest`.
    @Attribute(.unique) var key: String
    var kind: String
    /// Normalized source text, kept so a future cache browser or usage report can show what was looked up.
    var source: String
    /// The model's output: plain text for sentences, the raw JSON object for the other kinds.
    var payload: String
    var byteCount: Int
    var createdAt: Date
    var lastAccessed: Date
    var hitCount: Int

    init(key: TranslationCacheKey, source: String, payload: String) {
        self.key = key.digest
        self.kind = key.kind.rawValue
        self.source = source
        self.payload = payload
        self.byteCount = TranslationCachePolicy.estimatedBytes(source: source, payload: payload)
        self.createdAt = Date()
        self.lastAccessed = Date()
        self.hitCount = 0
    }
}

// MARK: - Schema versions
//
// Same rules as the vocabulary store: every change to `CacheEntry` gets a new schema version and a migration
// stage. The cache lives in its own file, so the vocabulary store is never touched by cache changes.

enum TranslationCacheSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [CacheEntry.self] }
}

enum TranslationCacheMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TranslationCacheSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

/// Local cache of successful model results, so selecting the same text again shows the answer instantly.
///
/// Lookups and single writes run on the main context. Anything that may touch many rows — recounting the size,
/// pruning expired entries, LRU eviction — runs one job at a time on a background context.
@MainActor
final class TranslationCache: ObservableObject {
    static let shared = TranslationCache()

    @Published private(set) var entryCount = 0
    @Published private(set) var approxBytes = 0
    /// Cumulative hits since the last "clear"; survives eviction of the entries that were hit.
    @Published private(set) var totalHits = 0
    /// True while a background recount / prune / eviction is running.
    @Published private(set) var isMaintaining = false

    private let container: ModelContainer
    private let inMemory: Bool
    private let settings = AppSettings.shared
    private var lastPrune = Date.distantPast
    private static let totalHitsKey = "translationCache.totalHits"
    /// Expired entries are pruned at launch and then at most this often, right after a write.
    private static let pruneInterval: TimeInterval = 3_600

    // Background job bookkeeping.
    private var needsRecount = false
    private var needsPrune = false
    /// Bumped by every main-context change to the counters; a recount that raced with one is redone.
    private var generation = 0

    private var context: ModelContext { container.mainContext }
    var isEnabled: Bool { settings.cacheEnabled }
    /// The user's size limit, clamped to the hard maximum.
    var limitBytes: Int { TranslationCachePolicy.effectiveLimit(settings.cacheSizeLimit.bytes) }

    private init() {
        (container, inMemory) = Self.openContainer()
        if !inMemory { totalHits = UserDefaults.standard.integer(forKey: Self.totalHitsKey) }
        // Keep housekeeping off the launch path.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.performMaintenance()
        }
    }

    private static func openContainer() -> (ModelContainer, Bool) {
        let schema = Schema(versionedSchema: TranslationCacheSchemaV1.self)
        func open(_ configuration: ModelConfiguration) throws -> ModelContainer {
            try ModelContainer(for: schema, migrationPlan: TranslationCacheMigrationPlan.self,
                               configurations: configuration)
        }
        func memoryContainer() -> ModelContainer {
            // An in-memory store with our own schema cannot reasonably fail.
            try! open(ModelConfiguration("TranslationCache", schema: schema, isStoredInMemoryOnly: true))
        }
        #if DEBUG
        // Debug mock runs never write the real cache.
        if MockClient.isEnabled { return (memoryContainer(), true) }
        #endif
        // Next to the vocabulary store, in our own folder.
        let dir = URL.applicationSupportDirectory.appending(path: "SwipeSay", directoryHint: .isDirectory)
        let url = dir.appending(path: "TranslationCache.store")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return (try open(ModelConfiguration(url: url)), false)
        } catch {
            // It is only a cache: throw away an unreadable store and start over rather than crash.
            NSLog("SwipeSay: cannot open translation cache, recreating it: \(error)")
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
            if let container = try? open(ModelConfiguration(url: url)) { return (container, false) }
            NSLog("SwipeSay: translation cache falls back to memory only")
            return (memoryContainer(), true)
        }
    }

    // MARK: Lookup / store

    /// Returns the cached result if the cache is on, the entry is within the retention period and `decode`
    /// accepts the payload. Entries that no longer decode (e.g. after a model type change) are dropped.
    func lookup<T>(_ key: TranslationCacheKey, decode: (String) throws -> T) -> (value: T, createdAt: Date)? {
        guard isEnabled, let entry = fetch(key) else { return nil }
        if isExpired(entry) {
            delete(entry)
            return nil
        }
        guard let value = try? decode(entry.payload) else {
            delete(entry)
            return nil
        }
        entry.lastAccessed = Date()
        entry.hitCount += 1
        try? context.save()
        totalHits += 1
        if !inMemory { UserDefaults.standard.set(totalHits, forKey: Self.totalHitsKey) }
        // Callers report the hit to `UsageTracker.recordCacheHit`, where the provider config is known.
        return (value, entry.createdAt)
    }

    /// Saves a successful, complete result, replacing any previous one for the same key.
    func store(_ key: TranslationCacheKey, source: String, payload: String) {
        guard isEnabled else { return }
        let payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }
        let source = TranslationCacheKey.normalize(source)
        if let existing = fetch(key) {
            approxBytes -= existing.byteCount
            existing.source = source
            existing.payload = payload
            existing.byteCount = TranslationCachePolicy.estimatedBytes(source: source, payload: payload)
            existing.createdAt = Date()
            existing.lastAccessed = Date()
            approxBytes += existing.byteCount
        } else {
            let entry = CacheEntry(key: key, source: source, payload: payload)
            context.insert(entry)
            entryCount += 1
            approxBytes += entry.byteCount
        }
        generation += 1
        try? context.save()
        if Date().timeIntervalSince(lastPrune) > Self.pruneInterval {
            needsPrune = true
            needsRecount = true
        }
        startBackgroundJob()
    }

    func remove(_ key: TranslationCacheKey) {
        if let entry = fetch(key) { delete(entry) }
    }

    func clear() {
        try? context.delete(model: CacheEntry.self)
        try? context.save()
        entryCount = 0
        approxBytes = 0
        generation += 1
        totalHits = 0
        if !inMemory { UserDefaults.standard.removeObject(forKey: Self.totalHitsKey) }
    }

    // MARK: Housekeeping

    /// Prunes expired entries, recounts the size and evicts if over the limit (in the background).
    func performMaintenance() {
        needsPrune = true
        needsRecount = true
        startBackgroundJob()
    }

    /// Deletes entries older than the retention period (measured from when the result was produced).
    func pruneExpired() {
        performMaintenance()
    }

    /// Recomputes the counters from the store (the incremental ones can drift, e.g. after a failed save).
    func refreshStats() {
        needsRecount = true
        startBackgroundJob()
    }

    /// Call after the size limit changed; a lower limit evicts right away.
    func sizeLimitChanged() {
        startBackgroundJob()
    }

    private struct JobResult: Sendable {
        /// Totals after pruning, before eviction; nil when no recount was requested.
        var recount: (count: Int, bytes: Int)?
        var evictedCount = 0
        var evictedBytes = 0
    }

    /// Runs at most one background job; when it finishes, it starts again if more work came in meanwhile or the
    /// cache is still over the limit.
    private func startBackgroundJob() {
        guard !isMaintaining else { return }
        let prune = needsPrune
        let recount = needsRecount || prune
        guard recount || approxBytes > limitBytes else { return }
        needsPrune = false
        needsRecount = false
        if prune { lastPrune = Date() }
        isMaintaining = true
        try? context.save()

        let container = self.container
        let cutoff = prune ? retentionCutoff : nil
        let total = approxBytes
        let limit = limitBytes
        let startGeneration = generation
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.runJob(container: container, pruneBefore: cutoff, recount: recount,
                                     total: total, limit: limit)
            await self?.finishBackgroundJob(result, startGeneration: startGeneration)
        }
    }

    private func finishBackgroundJob(_ result: JobResult, startGeneration: Int) {
        isMaintaining = false
        if generation != startGeneration {
            // A write or delete happened meanwhile, so the job's numbers are stale: recount once more.
            needsRecount = true
        } else if let recount = result.recount {
            entryCount = recount.count - result.evictedCount
            approxBytes = recount.bytes - result.evictedBytes
        } else {
            entryCount -= result.evictedCount
            approxBytes -= result.evictedBytes
        }
        // Without pending work, only go again if eviction made progress (avoids spinning on drifted counters).
        if needsRecount || needsPrune || result.evictedCount > 0 {
            startBackgroundJob()
        }
    }

    nonisolated private static func runJob(container: ModelContainer, pruneBefore cutoff: Date?, recount: Bool,
                                           total: Int, limit: Int) -> JobResult {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var result = JobResult()
        if let cutoff {
            try? context.delete(model: CacheEntry.self, where: #Predicate { $0.createdAt < cutoff })
            try? context.save()
        }
        var current = total
        if recount {
            let count = (try? context.fetchCount(FetchDescriptor<CacheEntry>())) ?? 0
            var descriptor = FetchDescriptor<CacheEntry>()
            descriptor.propertiesToFetch = [\.byteCount]
            let bytes = ((try? context.fetch(descriptor)) ?? []).reduce(0) { $0 + $1.byteCount }
            result.recount = (count, bytes)
            current = bytes
        }
        // Least-recently-used eviction once the estimated size passes the limit.
        guard current > limit else { return result }
        let target = TranslationCachePolicy.evictionTarget(forLimit: limit)
        while current > target {
            var descriptor = FetchDescriptor<CacheEntry>(sortBy: [SortDescriptor(\.lastAccessed)])
            descriptor.fetchLimit = 500
            guard let batch = try? context.fetch(descriptor), !batch.isEmpty else { break }
            let count = TranslationCachePolicy.evictionCount(oldestFirst: batch.map(\.byteCount),
                                                             total: current, target: target)
            for entry in batch.prefix(count) {
                current -= entry.byteCount
                result.evictedCount += 1
                result.evictedBytes += entry.byteCount
                context.delete(entry)
            }
            try? context.save()
            if count < batch.count { break }
        }
        return result
    }

    private var retentionCutoff: Date? {
        settings.cacheRetention.days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
    }

    private func isExpired(_ entry: CacheEntry) -> Bool {
        guard let cutoff = retentionCutoff else { return false }
        return entry.createdAt < cutoff
    }

    private func fetch(_ key: TranslationCacheKey) -> CacheEntry? {
        let digest = key.digest
        var descriptor = FetchDescriptor<CacheEntry>(predicate: #Predicate { $0.key == digest })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func delete(_ entry: CacheEntry) {
        approxBytes -= entry.byteCount
        entryCount -= 1
        generation += 1
        context.delete(entry)
        try? context.save()
    }
}
