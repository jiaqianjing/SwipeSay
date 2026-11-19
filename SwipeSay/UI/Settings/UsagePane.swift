import SwiftUI
import SwipeSayKit
import Charts
import AppKit
import UniformTypeIdentifiers

// MARK: - Usage

struct UsagePane: View {
    @State private var records: [UsageRecord] = []
    @State private var loaded = false
    @State private var range: UsageRange = .week
    @State private var grouping: UsageGrouping = .model
    @State private var confirmClear = false
    @AppStorage("usage.showEstimatedCost") private var showCost = false

    var body: some View {
        Pane(title: "用量") {
            if loaded && records.isEmpty {
                Text("还没有用量记录。翻译几次后，这里会按服务和模型显示消耗的 token。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                summaryCard
                chartCard
                detailCard
                kindCard
                notes
            }
            settingsCard
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: UsageTracker.didChange)) { _ in
            Task { await reload() }
        }
        .confirmationDialog("清空所有用量记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { Task { await UsageTracker.removeAll() } }
        } message: {
            Text("此操作无法撤销。")
        }
    }

    private func reload() async {
        let since = UsageMath.startOfDay(daysAgo: UsageRange.allCases.map(\.days).max()! - 1)
        records = await UsageTracker.records(since: since)
        loaded = true
    }

    // MARK: Summary

    private var summaryCard: some View {
        HStack(spacing: 10) {
            summaryTile("今天", UsageMath.records(records, lastDays: 1))
            summaryTile("近 7 天", UsageMath.records(records, lastDays: 7))
            summaryTile("近 30 天", UsageMath.records(records, lastDays: 30))
        }
    }

    private func summaryTile(_ title: String, _ rows: [UsageRecord]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(UsageFormat.tokens(rows.reduce(0) { $0 + $1.totalTokens }, estimated: rows.contains(where: \.hasEstimate),
                                    compact: true))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text("token · \(rows.reduce(0) { $0 + $1.requests }) 次请求")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if showCost {
                Text(UsageFormat.costSummary(rows))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Chart

    private var rangeRecords: [UsageRecord] { UsageMath.records(records, lastDays: range.days) }

    private var chartCard: some View {
        SettingsCard(header: rangeRecords.contains(where: \.hasEstimate) ? "每日 token（含估算）" : "每日 token") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("", selection: $range) {
                        ForEach(UsageRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    Spacer()
                    Picker("分组", selection: $grouping) {
                        ForEach(UsageGrouping.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 150)
                }
                let points = UsageMath.chartPoints(rangeRecords, days: range.days, grouping: grouping)
                Chart(points) { point in
                    LineMark(x: .value("日期", point.day, unit: .day), y: .value("Token", point.tokens))
                        .foregroundStyle(by: .value("分组", point.series))
                    PointMark(x: .value("日期", point.day, unit: .day), y: .value("Token", point.tokens))
                        .foregroundStyle(by: .value("分组", point.series))
                        .symbolSize(range == .week ? 24 : 8)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: range.axisStride)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Int.self) { Text(UsageFormat.compact(v)) } }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 220)
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: Details

    private var detailCard: some View {
        let groups = UsageMath.providerGroups(rangeRecords)
        return SettingsCard(header: "按服务和模型 · \(range.title)") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("模型")
                    Text("请求").gridColumnAlignment(.trailing)
                    Text("输入").gridColumnAlignment(.trailing)
                    Text("输出").gridColumnAlignment(.trailing)
                    Text("合计").gridColumnAlignment(.trailing)
                    if showCost { Text("估算费用").gridColumnAlignment(.trailing) }
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(groups) { group in
                    Divider()
                    GridRow {
                        Text(group.name).font(.system(size: 12, weight: .semibold))
                            .gridCellColumns(showCost ? 6 : 5)
                    }
                    ForEach(group.models) { model in
                        GridRow {
                            Text(model.model.isEmpty ? "未知模型" : model.model)
                                .lineLimit(1).truncationMode(.middle)
                            Text("\(model.requests)")
                            Text(UsageFormat.tokens(model.input, estimated: model.hasEstimate))
                            Text(UsageFormat.tokens(model.output, estimated: model.hasEstimate))
                            Text(UsageFormat.tokens(model.input + model.output, estimated: model.hasEstimate))
                            if showCost { Text(UsageFormat.cost(model.records)) }
                        }
                        .font(.system(size: 12).monospacedDigit())
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    private var kindCard: some View {
        let rows = UsageMath.kindTotals(rangeRecords)
        let total = max(1, rows.reduce(0) { $0 + $1.tokens })
        return SettingsCard(header: "按功能 · \(range.title)") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(rows, id: \.kind) { row in
                    GridRow {
                        Text(row.kind.displayName).font(.system(size: 12))
                        Text("\(row.requests) 次").gridColumnAlignment(.trailing)
                        Text(UsageFormat.tokens(row.tokens, estimated: row.estimated)).gridColumnAlignment(.trailing)
                        GeometryReader { geo in
                            Capsule().fill(Theme.accent.opacity(0.7))
                                .frame(width: max(2, geo.size.width * CGFloat(row.tokens) / CGFloat(total)))
                        }
                        .frame(height: 6)
                    }
                    .font(.system(size: 12).monospacedDigit())
                }
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var notes: some View {
        let rows = rangeRecords
        let estimated = rows.reduce(0) { $0 + $1.estimatedRequests }
        let incomplete = rows.reduce(0) { $0 + $1.incomplete }
        let cacheHits = rows.reduce(0) { $0 + $1.cacheHits }
        let parts = [
            estimated > 0 ? "\(estimated) 次请求服务未返回用量，token 按字数估算（标「约」的数字含估算）" : nil,
            incomplete > 0 ? "\(incomplete) 次请求失败或被取消" : nil,
            cacheHits > 0 ? "\(cacheHits) 次结果来自本地缓存，未消耗 token" : nil,
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: "；") + "。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: Settings

    private var settingsCard: some View {
        SettingsCard(header: "设置") {
            SettingsRow(title: "显示估算费用",
                        subtitle: "按内置价格表估算（更新于 \(UsagePricing.updated)），只覆盖部分官方模型；估算，以账单为准。ChatGPT 订阅显示「订阅内」。") {
                Toggle("", isOn: $showCost).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            SettingsRow(title: "用量记录", subtitle: "只保存日期、服务、模型、请求类型和 token 数，不保存原文和译文") {
                HStack {
                    Button("导出 CSV…") { Task { await exportCSV() } }
                    Button("清空用量记录", role: .destructive) { confirmClear = true }
                }
                .controlSize(.small)
            }
        }
    }

    @MainActor
    private func exportCSV() async {
        let all = await UsageTracker.records(since: .distantPast)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "SwipeSay-用量.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? UsageFormat.csv(all).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Model

enum UsageRange: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, quarter = 90

    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String { "\(rawValue) 天" }
    var axisStride: Int {
        switch self {
        case .week: return 1
        case .month: return 5
        case .quarter: return 15
        }
    }
}

enum UsageGrouping: String, CaseIterable, Identifiable {
    case model, provider, kind

    var id: String { rawValue }
    var title: String {
        switch self {
        case .model: return "按模型"
        case .provider: return "按服务"
        case .kind: return "按功能"
        }
    }
}

struct UsageChartPoint: Identifiable {
    var day: Date
    var series: String
    var tokens: Int
    var id: String { "\(series)|\(day.timeIntervalSinceReferenceDate)" }
}

struct UsageModelTotal: Identifiable {
    var model: String
    var records: [UsageRecord]
    var id: String { model }
    var requests: Int { records.reduce(0) { $0 + $1.requests } }
    /// Reported plus estimated tokens.
    var input: Int { records.reduce(0) { $0 + $1.allInputTokens } }
    var output: Int { records.reduce(0) { $0 + $1.allOutputTokens } }
    var hasEstimate: Bool { records.contains(where: \.hasEstimate) }
}

struct UsageProviderGroup: Identifiable {
    var name: String
    var models: [UsageModelTotal]
    var id: String { name }
}

enum UsageMath {
    static func startOfDay(daysAgo: Int) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
    }

    static func records(_ all: [UsageRecord], lastDays: Int) -> [UsageRecord] {
        let start = startOfDay(daysAgo: lastDays - 1)
        return all.filter { $0.day >= start }
    }

    /// Daily tokens per series, zero-filled so lines don't skip quiet days; small series fold into「其他」.
    static func chartPoints(_ rows: [UsageRecord], days: Int, grouping: UsageGrouping, maxSeries: Int = 5) -> [UsageChartPoint] {
        let label = seriesLabel(rows, grouping: grouping)
        var totals: [String: Int] = [:]
        for r in rows { totals[label(r), default: 0] += r.totalTokens }
        let ranked = totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        let kept = Set(ranked.prefix(ranked.count > maxSeries ? maxSeries - 1 : maxSeries))
        let other = "其他"
        let series = ranked.filter { kept.contains($0) } + (ranked.count > kept.count ? [other] : [])

        var byDay: [Date: [String: Int]] = [:]
        for r in rows {
            let name = kept.contains(label(r)) ? label(r) : other
            byDay[r.day, default: [:]][name, default: 0] += r.totalTokens
        }
        let calendar = Calendar.current
        return (0..<days).reversed().flatMap { offset -> [UsageChartPoint] in
            let day = startOfDay(daysAgo: offset)
            let values = byDay.first { calendar.isDate($0.key, inSameDayAs: day) }?.value ?? [:]
            return series.map { UsageChartPoint(day: day, series: $0, tokens: values[$0] ?? 0) }
        }
    }

    private static func seriesLabel(_ rows: [UsageRecord], grouping: UsageGrouping) -> (UsageRecord) -> String {
        switch grouping {
        case .provider:
            return { $0.providerName }
        case .kind:
            return { $0.usageKind.displayName }
        case .model:
            // The same model id can come from two services (e.g. API key and ChatGPT plan); keep them apart.
            var providers: [String: Set<String>] = [:]
            for r in rows { providers[r.model, default: []].insert(r.providerName) }
            return { r in
                let name = r.model.isEmpty ? "未知模型" : r.model
                return (providers[r.model]?.count ?? 0) > 1 ? "\(name) · \(r.providerName)" : name
            }
        }
    }

    static func providerGroups(_ rows: [UsageRecord]) -> [UsageProviderGroup] {
        let byProvider = Dictionary(grouping: rows, by: \.providerName)
        return byProvider.map { name, rows in
            let models = Dictionary(grouping: rows, by: \.model)
                .map { UsageModelTotal(model: $0.key, records: $0.value) }
                .sorted { $0.input + $0.output > $1.input + $1.output }
            return UsageProviderGroup(name: name, models: models)
        }
        .sorted { a, b in
            a.models.reduce(0) { $0 + $1.input + $1.output } > b.models.reduce(0) { $0 + $1.input + $1.output }
        }
    }

    static func kindTotals(_ rows: [UsageRecord]) -> [(kind: UsageKind, requests: Int, tokens: Int, estimated: Bool)] {
        Dictionary(grouping: rows, by: \.usageKind)
            .map { (kind: $0.key, requests: $0.value.reduce(0) { $0 + $1.requests },
                    tokens: $0.value.reduce(0) { $0 + $1.totalTokens }, estimated: $0.value.contains(where: \.hasEstimate)) }
            .sorted { $0.tokens > $1.tokens }
    }
}

enum UsageFormat {
    static func compact(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func grouped(_ n: Int) -> String { n.formatted(.number) }

    /// Token count, prefixed with 「约」 when it includes local estimates.
    static func tokens(_ n: Int, estimated: Bool, compact useCompact: Bool = false) -> String {
        let text = useCompact ? compact(n) : grouped(n)
        return estimated ? "约 \(text)" : text
    }

    static func usd(_ v: Double) -> String {
        if v == 0 { return "$0" }
        return v < 0.01 ? String(format: "$%.4f", v) : String(format: "$%.2f", v)
    }

    /// Cost cell for one model's rows: an estimate, 「订阅内」 for the ChatGPT plan, or 「—」 when unpriced.
    static func cost(_ rows: [UsageRecord]) -> String {
        if rows.allSatisfy({ $0.provider == .chatGPT }) { return "订阅内" }
        let costs = rows.map(UsagePricing.cost)
        guard !costs.contains(where: { $0 == nil }) else { return "—" }
        let text = usd(costs.reduce(0) { $0 + ($1 ?? 0) })
        return rows.contains(where: \.hasEstimate) ? "约 \(text)" : text
    }

    static func costSummary(_ rows: [UsageRecord]) -> String {
        let billed = rows.filter { $0.provider != .chatGPT && $0.totalTokens > 0 }
        if billed.isEmpty { return rows.isEmpty ? "估算费用 $0" : "估算费用：订阅内" }
        let priced = billed.compactMap(UsagePricing.cost)
        let total = "估算费用 ≈ \(usd(priced.reduce(0, +)))"
        return priced.count < billed.count ? total + "（部分模型无价格）" : total
    }

    static func csv(_ rows: [UsageRecord]) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["date,provider_kind,provider,model,kind,requests,incomplete,cache_hits,input_tokens,cached_input_tokens,"
                     + "output_tokens,estimated_requests,estimated_input_tokens,estimated_output_tokens"]
        for r in rows {
            lines.append(([fmt.string(from: r.day), r.providerKind, r.providerName, r.model, r.kind].map(esc)
                          + [r.requests, r.incomplete, r.cacheHits, r.inputTokens, r.cachedInputTokens, r.outputTokens,
                             r.estimatedRequests, r.estimatedInputTokens, r.estimatedOutputTokens].map(String.init))
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
