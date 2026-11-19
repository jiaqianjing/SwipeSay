import Foundation

/// Cost estimates for the usage page, using the dated reference prices in `ModelCatalog` (the single price table,
/// shared with the model picker). The UI always labels the result as an estimate.
///
/// Simplifications, acceptable for SwipeSay's short prompts (a few thousand tokens at most):
/// - Totals are aggregated per day, so per-request long-prompt tiers cannot be applied; the base tier is used.
/// - Anthropic cache writes are counted as regular input (SwipeSay does not set cache breakpoints).
/// - Only models in the table are priced; DeepSeek, ChatGPT and OpenAI-compatible gateways show no cost.
public enum UsagePricing {
    public static var updated: String { ModelCatalog.pricesCheckedOn }

    /// The price for a model, matching the exact id or a dated snapshot of it (e.g. `claude-haiku-5-5-20261001`).
    public static func price(kind: ProviderKind, model: String) -> ModelPrice.Rates? {
        var id = model.lowercased().trimmingCharacters(in: .whitespaces)
        if id.hasPrefix("models/") { id.removeFirst(7) }
        if let exact = ModelCatalog.price(for: id, kind: kind) { return exact.base }
        // Dated snapshot: strip a trailing "-<digits…>" suffix and retry.
        if let dash = id.lastIndex(of: "-"), id[id.index(after: dash)...].first?.isNumber == true {
            var base = String(id[..<dash])
            while ModelCatalog.price(for: base, kind: kind) == nil,
                  let d = base.lastIndex(of: "-"), base[base.index(after: d)...].allSatisfy(\.isNumber) {
                base = String(base[..<d])
            }
            return ModelCatalog.price(for: base, kind: kind)?.base
        }
        return nil
    }

    /// Estimated USD for a usage row (locally estimated tokens included, as uncached input), or nil when the
    /// model is not in the table.
    public static func cost(_ record: UsageRecord) -> Double? {
        guard let kind = record.provider, let price = price(kind: kind, model: record.model) else { return nil }
        let cached = min(record.cachedInputTokens, record.inputTokens)
        let uncached = record.allInputTokens - cached
        return (Double(uncached) * price.input + Double(cached) * (price.cachedInput ?? price.input)
                + Double(record.allOutputTokens) * price.output) / 1_000_000
    }
}
