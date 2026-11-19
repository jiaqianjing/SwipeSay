import SwiftUI

// MARK: - Follow-up conversation

struct FollowUpConversation: View {
    @ObservedObject var model: PopupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                Text("追问").font(.system(size: Theme.fs(10), weight: .semibold)).foregroundStyle(.tertiary)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
            }
            ForEach(model.followUps) { turn in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 48)
                        Text(turn.question)
                            .font(.system(size: Theme.fs(12.5)))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    answer(turn)
                }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func answer(_ turn: PopupViewModel.FollowUpTurn) -> some View {
        switch turn.phase {
        case .idle, .loading:
            ShimmerLines(lines: 2).padding(.vertical, 2)
        case .failed(let message):
            ErrorBanner(message: message, showSettings: false) { model.retryFollowUp(turn.id) }
        case .streaming, .done:
            (Text(turn.answer) + Text(turn.phase == .streaming ? " ▍" : "").foregroundColor(Theme.accent))
                .font(.system(size: Theme.fs(13)))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Word card

struct WordCardView: View {
    @ObservedObject var model: PopupViewModel
    var word: WordResult
    @EnvironmentObject private var vocab: VocabularyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let term = word.term ?? model.sourceText
                let phonetic = word.phonetic ?? ""
                // A stress-marked spelling (Russian "молоко́") replaces the headword rather than repeating it.
                let marked = Phonetic.isMarkedSpelling(phonetic, of: term)
                Text(marked ? phonetic : term)
                    .font(.system(size: Theme.fs(21), weight: .semibold))
                    .textSelection(.enabled)
                if !marked, !phonetic.isEmpty {
                    Text(phonetic).font(.system(size: Theme.fs(13))).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.plan.sourceIsNative {
                    StarButton(saved: vocab.savedKeys.contains(VocabItem.normalize(model.wordTerm))) { model.toggleSaveWord() }
                }
            }
            if let lemma = word.lemma, !lemma.isEmpty, lemma.lowercased() != (word.term ?? "").lowercased() {
                let lemmaPhonetic = word.lemmaPhonetic ?? ""
                Text("原形：\(Phonetic.isMarkedSpelling(lemmaPhonetic, of: lemma) ? lemmaPhonetic : lemma)")
                    .font(.system(size: Theme.fs(11))).foregroundStyle(.secondary)
            }
            if let meaning = word.contextMeaning, !meaning.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TagView(text: model.usedContext ? "语境义" : "释义")
                    Text(meaning).font(.system(size: Theme.fs(15), weight: .medium)).textSelection(.enabled)
                }
            }
            if let senses = word.senses, !senses.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(senses, id: \.self) { sense in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(sense.pos ?? "")
                                .font(.system(size: Theme.fs(11.5), weight: .semibold).italic())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(minWidth: 38, alignment: .leading)
                            Text(sense.meaning ?? "").font(.system(size: Theme.fs(13))).textSelection(.enabled)
                        }
                    }
                }
            }
            if let forms = word.forms, !forms.isEmpty {
                WordFormsView(model: model, forms: forms)
            }
            if let ex = word.example, let src = ex.source, !src.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.highlight).frame(width: 2.5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(src).font(.system(size: Theme.fs(12.5))).italic().textSelection(.enabled)
                        if let t = ex.target, !t.isEmpty { Text(t).font(.system(size: Theme.fs(12))).foregroundStyle(.secondary) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let note = word.note, !note.isEmpty {
                Label { Text(note) } icon: { Image(systemName: "lightbulb").foregroundStyle(Theme.highlight) }
                    .font(.system(size: Theme.fs(12)))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Declension / conjugation: a one-line summary, with the full tables behind a toggle.
struct WordFormsView: View {
    @ObservedObject var model: PopupViewModel
    var forms: WordResult.Forms

    var body: some View {
        let tables = forms.visibleTables
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TagView(text: "词形")
                if let summary = forms.summary, !summary.isEmpty {
                    Text(summary).font(.system(size: Theme.fs(12.5))).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !tables.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.formsExpanded.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text(model.formsExpanded ? "收起" : "变化表")
                            Image(systemName: "chevron.down")
                                .font(.system(size: Theme.fs(8), weight: .bold))
                                .rotationEffect(.degrees(model.formsExpanded ? 180 : 0))
                        }
                        .font(.system(size: Theme.fs(11), weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            if model.formsExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(tables, id: \.self) { FormsTableView(table: $0) }
                }
                .transition(.opacity)
            }
        }
    }
}

struct FormsTableView: View {
    var table: WordResult.Forms.Table

    var body: some View {
        let columns = table.columns ?? []
        let rows = table.rows ?? []
        let width = max(columns.count, rows.map { ($0.cells ?? []).count }.max() ?? 0)
        VStack(alignment: .leading, spacing: 4) {
            if let title = table.title, !title.isEmpty {
                Text(title).font(.system(size: Theme.fs(11), weight: .semibold)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                if !columns.isEmpty {
                    GridRow {
                        Text("")
                        ForEach(0..<width, id: \.self) { i in
                            Text(i < columns.count ? columns[i] : "")
                                .font(.system(size: Theme.fs(10.5), weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label ?? "").font(.system(size: Theme.fs(11))).foregroundStyle(.secondary)
                        ForEach(0..<width, id: \.self) { i in
                            let cells = row.cells ?? []
                            Text(i < cells.count ? cells[i] : "").font(.system(size: Theme.fs(12.5)))
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

// MARK: - Capsule: key expressions + analysis

struct CapsuleSection: View {
    @ObservedObject var model: PopupViewModel
    @EnvironmentObject private var vocab: VocabularyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                capsuleButton
                if model.keyItems?.analysisWorthy == true {
                    analyzeButton
                }
                Spacer(minLength: 0)
            }
            if model.capsuleExpanded {
                expandedItems
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            switch model.analysisPhase {
            case .loading: ShimmerLines(lines: 4).padding(.top, 2)
            case .failed(let msg): ErrorBanner(message: msg, showSettings: false) { model.analysis = nil; model.analysisPhase = .idle; model.loadAnalysis() }
            default: EmptyView()
            }
            if let analysis = model.analysis {
                AnalysisView(analysis: analysis).transition(.opacity)
            }
        }
        .padding(.top, 2)
    }

    private var capsuleButton: some View {
        Button { model.toggleCapsule() } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: Theme.fs(10), weight: .bold))
                Text("重点表达")
                if let n = model.keyItems?.items?.count, model.keyItemsPhase == .done {
                    Text("\(n)").font(.system(size: Theme.fs(10), weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                }
                if model.keyItemsPhase == .loading {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: Theme.fs(9), weight: .bold))
                    .rotationEffect(.degrees(model.capsuleExpanded ? 180 : 0))
            }
            .font(.system(size: Theme.fs(11.5), weight: .semibold))
            .foregroundStyle(Color(red: 0.55, green: 0.38, blue: 0.0))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.highlight.opacity(0.28), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("提取值得记住的词组和单词")
    }

    private var analyzeButton: some View {
        Button { model.loadAnalysis() } label: {
            HStack(spacing: 5) {
                Image(systemName: model.analysis == nil ? "text.magnifyingglass" : "chevron.up")
                    .font(.system(size: Theme.fs(10), weight: .bold))
                Text(model.analysis == nil ? "解析句子" : "收起解析")
                if model.analysis == nil, let hint = model.keyItems?.analysisHint, !hint.isEmpty {
                    Text("· \(hint)").lineLimit(1).foregroundStyle(Theme.accent.opacity(0.75))
                }
            }
            .font(.system(size: Theme.fs(11.5), weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.accent.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("这句话值得细看：按需生成成分 / 语气分析")
    }

    @ViewBuilder private var expandedItems: some View {
        switch model.keyItemsPhase {
        case .loading, .idle:
            ShimmerLines(lines: 3)
        case .failed(let msg):
            ErrorBanner(message: msg, showSettings: false) { model.loadKeyItems() }
        case .streaming, .done:
            let items = model.keyItems?.items ?? []
            if items.isEmpty {
                Text("这句没有特别需要记的表达 👌")
                    .font(.system(size: Theme.fs(12))).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        KeyItemRow(item: item, saved: vocab.savedKeys.contains(VocabItem.normalize(item.text))) {
                            model.toggleSave(item)
                        }
                    }
                }
            }
        }
    }
}

struct KeyItemRow: View {
    var item: KeyItem
    var saved: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.text).font(.system(size: Theme.fs(13.5), weight: .semibold)).textSelection(.enabled)
                    TagView(text: item.kindLabel, color: Color(red: 0.75, green: 0.52, blue: 0.0))
                    if let p = item.phonetic, !p.isEmpty {
                        Text(p).font(.system(size: Theme.fs(11))).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let m = item.meaning, !m.isEmpty {
                    Text(m).font(.system(size: Theme.fs(12.5))).foregroundStyle(.primary.opacity(0.85))
                }
                if let n = item.note, !n.isEmpty {
                    Text(n).font(.system(size: Theme.fs(11.5))).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            StarButton(saved: saved, action: onToggle)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct StarButton: View {
    var saved: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: saved ? "star.fill" : "star")
                .font(.system(size: Theme.fs(13)))
                .foregroundStyle(saved ? Theme.highlight : .secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(saved ? "已在生词本（点击移除）" : "加入生词本")
    }
}

struct AnalysisView: View {
    var analysis: SentenceAnalysis

    private let roleColors: [Color] = [
        Color(red: 0.95, green: 0.39, blue: 0.36), Color(red: 0.22, green: 0.55, blue: 0.85),
        Color(red: 0.30, green: 0.65, blue: 0.40), Color(red: 0.62, green: 0.40, blue: 0.80),
        Color(red: 0.85, green: 0.55, blue: 0.10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(analysis.kind == "expression" ? "表达解析" : "句子解析", systemImage: "text.magnifyingglass")
                .font(.system(size: Theme.fs(12), weight: .semibold))
                .foregroundStyle(Theme.accent)

            if let skeleton = analysis.skeleton, !skeleton.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("主干").font(.system(size: Theme.fs(10.5), weight: .semibold)).foregroundStyle(.secondary)
                    Text(skeleton).font(.system(size: Theme.fs(13.5), weight: .semibold)).textSelection(.enabled)
                    if let t = analysis.skeletonTranslation, !t.isEmpty {
                        Text(t).font(.system(size: Theme.fs(12))).foregroundStyle(.secondary)
                    }
                }
            }

            if let chunks = analysis.chunks, !chunks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { idx, chunk in
                        HStack(alignment: .top, spacing: 8) {
                            TagView(text: chunk.role ?? "", color: roleColors[idx % roleColors.count])
                                .fixedSize()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chunk.text ?? "").font(.system(size: Theme.fs(12.5), weight: .medium)).textSelection(.enabled)
                                if let e = chunk.explain, !e.isEmpty {
                                    Text(e).font(.system(size: Theme.fs(11.5))).foregroundStyle(.secondary)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let usage = analysis.usage, !usage.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("语境与语气").font(.system(size: Theme.fs(10.5), weight: .semibold)).foregroundStyle(.secondary)
                    Text(usage).font(.system(size: Theme.fs(12.5))).textSelection(.enabled)
                }
            }

            if let insights = analysis.insights, !insights.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(insights, id: \.self) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "lightbulb.fill").font(.system(size: Theme.fs(9))).foregroundStyle(Theme.highlight)
                            Text(s).font(.system(size: Theme.fs(12.5)))
                        }
                    }
                }
            }

            if let p = analysis.paraphrase, !p.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("换个说法").font(.system(size: Theme.fs(10.5), weight: .semibold)).foregroundStyle(.secondary)
                    Text(p).font(.system(size: Theme.fs(12.5))).italic().textSelection(.enabled)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.highlight.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.highlight.opacity(0.3), lineWidth: 0.5))
    }
}

struct ErrorBanner: View {
    var message: String
    var showSettings: Bool
    var retry: () -> Void
    #if os(iOS)
    @Environment(\.openProviderSettings) private var openProviderSettings
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: Theme.fs(12)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if showSettings {
                    #if os(macOS)
                    Button("打开设置") {
                        PopupController.shared.close()
                        WindowManager.shared.showSettings(tab: .providers)
                    }
                    #else
                    if let openProviderSettings {
                        Button("打开设置", action: openProviderSettings)
                    }
                    #endif
                } else {
                    Button("重试", action: retry)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: Theme.fs(11.5), weight: .semibold))
            .foregroundStyle(Theme.accent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

#if os(iOS)
private struct OpenProviderSettingsKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Shows the model-service settings; nil where that isn't possible (the action extension).
    var openProviderSettings: (() -> Void)? {
        get { self[OpenProviderSettingsKey.self] }
        set { self[OpenProviderSettingsKey.self] = newValue }
    }
}
#endif
