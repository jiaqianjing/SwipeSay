import SwiftUI
import AppKit

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TotalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct FollowUpBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PopupRootView: View {
    @ObservedObject var model: PopupViewModel
    var maxHeight: CGFloat
    var onHeight: (CGFloat) -> Void

    @EnvironmentObject private var vocab: VocabularyStore
    @State private var contentHeight: CGFloat = 40
    @State private var followUpBarHeight: CGFloat = 0
    @State private var showContext = false
    @FocusState private var inputFocused: Bool
    @FocusState private var followUpFocused: Bool

    /// Room left for the scrolling content once header, footer and the follow-up box are laid out.
    private var scrollLimit: CGFloat { maxHeight - 90 - (model.canFollowUp ? followUpBarHeight : 0) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: contentHeight > scrollLimit) {
                        content
                            .background(GeometryReader { g in
                                Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                            })
                    }
                    .frame(height: min(contentHeight, scrollLimit))
                    .onChange(of: model.followUps.count) { scrollToConversationEnd(proxy) }
                    .onChange(of: model.followUps.last?.answer) {
                        if model.isFollowUpBusy { scrollToConversationEnd(proxy) }
                    }
                }
                if model.canFollowUp {
                    followUpBar
                        .background(GeometryReader { g in
                            Color.clear.preference(key: FollowUpBarHeightKey.self, value: g.size.height)
                        })
                }
                footer
            }
            .frame(width: Theme.popupWidth)
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            )
            .background(GeometryReader { g in
                Color.clear.preference(key: TotalHeightKey.self, value: g.size.height)
            })
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ContentHeightKey.self) { h in contentHeight = h }
        .onPreferenceChange(FollowUpBarHeightKey.self) { h in followUpBarHeight = h }
        .onPreferenceChange(TotalHeightKey.self) { h in onHeight(h) }
        .onAppear { if model.isInputMode { inputFocused = true } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            // Labels let clicks through to the drag area behind the header.
            sourceIcon.allowsHitTesting(false)
            Text(sourceTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .allowsHitTesting(false)
            if model.usedContext {
                Button { showContext.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "text.below.photo").font(.system(size: 9, weight: .semibold))
                        Text("已结合上下文")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("查看参与理解的上下文")
                .popover(isPresented: $showContext, arrowEdge: .bottom) {
                    ScrollView {
                        Text(model.captured.context ?? "")
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(width: 320, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
            }
            Spacer(minLength: 4)
            IconButton(systemName: "speaker.wave.2", help: "朗读") {
                Speaker.speak(model.plan.mode == .word ? model.wordTerm : model.learningSentence)
            }
            IconButton(systemName: "doc.on.doc", help: "复制译文") { NSPasteboard.copy(model.translation) }
                .disabled(model.translation.isEmpty)
            IconButton(systemName: model.pinned ? "pin.fill" : "pin", help: model.pinned ? "取消固定" : "固定窗口", active: model.pinned) {
                model.pinned.toggle()
            }
            IconButton(systemName: "xmark", help: "关闭 (Esc)") { PopupController.shared.close() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(WindowDragArea(onMoved: model.didMoveWindow))
    }

    @ViewBuilder private var sourceIcon: some View {
        switch model.captured.origin {
        case .screenshot:
            Image(systemName: "viewfinder").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        case .manual:
            Image(systemName: "keyboard").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        case .selection:
            if let id = model.captured.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 15, height: 15)
            } else {
                Image(systemName: "highlighter").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var sourceTitle: String {
        switch model.captured.origin {
        case .screenshot: return "截图识别"
        case .manual: return "输入翻译"
        case .selection: return model.captured.appName ?? "划词"
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isInputMode {
                inputField
            } else if model.plan.mode == .sentence || model.word == nil {
                sourceView
            }
            resultView
            if model.canShowCapsule {
                CapsuleSection(model: model)
            }
            if !model.followUps.isEmpty {
                FollowUpConversation(model: model)
                    .id(Self.conversationEndID)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, model.canFollowUp ? 6 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Follow-up

    private static let conversationEndID = "conversation-end"

    private func scrollToConversationEnd(_ proxy: ScrollViewProxy) {
        // Wait one runloop so the new content height has been measured.
        DispatchQueue.main.async { proxy.scrollTo(Self.conversationEndID, anchor: .bottom) }
    }

    /// Return sends; ⇧↩ inserts a newline (handled by `PopupController`'s key monitor).
    private var followUpBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("追问这段内容…", text: $model.followUpDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused($followUpFocused)
                .onSubmit { model.sendFollowUp() }
            Button { model.sendFollowUp() } label: {
                Image(systemName: model.isFollowUpBusy ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canSendFollowUp ? Theme.accent : Color.secondary.opacity(0.45))
            .disabled(!model.canSendFollowUp)
            .help(model.isFollowUpBusy ? "正在回答…" : "发送 (↩)，⇧↩ 换行")
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(followUpFocused ? Theme.accent.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 2)
    }

    private var inputField: some View {
        TextField("输入要翻译的内容，回车翻译", text: $model.sourceText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(1...8)
            .focused($inputFocused)
            .onSubmit { model.submitInput() }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sourceView: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.accent.opacity(0.75))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(highlightedSource)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .lineLimit(model.sourceExpanded ? nil : 4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if model.sourceText.count > 220 {
                    Button(model.sourceExpanded ? "收起" : "展开原文") { model.sourceExpanded.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Marks extracted key expressions in the source like a highlighter.
    private var highlightedSource: AttributedString {
        var attributed = AttributedString(model.sourceText)
        guard model.capsuleExpanded, !model.plan.sourceIsNative, let items = model.keyItems?.items else { return attributed }
        for item in items {
            var searchRange = attributed.startIndex..<attributed.endIndex
            while let range = attributed[searchRange].range(of: item.text, options: [.caseInsensitive, .diacriticInsensitive]) {
                attributed[range].backgroundColor = Theme.highlight.opacity(0.35)
                attributed[range].foregroundColor = .primary
                searchRange = range.upperBound..<attributed.endIndex
            }
        }
        return attributed
    }

    @ViewBuilder private var resultView: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .loading:
            ShimmerLines(lines: model.plan.mode == .word ? 3 : 2).padding(.vertical, 4)
        case .failed(let message):
            ErrorBanner(message: message, showSettings: model.notConfigured) { model.translate() }
        case .streaming, .done:
            if model.plan.mode == .word, let word = model.word {
                WordCardView(model: model, word: word)
            } else {
                (Text(model.translation) + Text(model.phase == .streaming ? " ▍" : "").foregroundColor(Theme.accent))
                    .font(.system(size: 15))
                    .lineSpacing(3.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.system(size: 9)).allowsHitTesting(false)
            Text(model.providerLabel.isEmpty ? "未配置模型" : model.providerLabel)
                .lineLimit(1)
                .allowsHitTesting(false)
            Spacer()
            if let cachedAt = model.cachedAt {
                Text("⚡ 来自缓存 · \(TranslationCachePolicy.age(since: cachedAt))")
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help("结果来自本机缓存，没有请求模型")
                Button { model.retranslate() } label: {
                    Text("重新翻译").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .fixedSize()
                .help("忽略缓存重新请求，并更新缓存")
                .padding(.trailing, 4)
            }
            if model.isInputMode {
                Button { model.submitInput() } label: {
                    Text("翻译 ↩").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .padding(.trailing, 6)
            }
            Menu {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        model.setTarget(lang)
                    } label: {
                        if lang == model.currentTarget { Label(lang.displayName, systemImage: "checkmark") } else { Text(lang.displayName) }
                    }
                }
            } label: {
                Text("译为 \(model.currentTarget.displayName)")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(WindowDragArea(onMoved: model.didMoveWindow)) // above the fill, which would take the clicks
        .background(Color.primary.opacity(0.035))
    }
}

// MARK: - Follow-up conversation

struct FollowUpConversation: View {
    @ObservedObject var model: PopupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                Text("追问").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
            }
            ForEach(model.followUps) { turn in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 48)
                        Text(turn.question)
                            .font(.system(size: 12.5))
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
                .font(.system(size: 13))
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
                    .font(.system(size: 21, weight: .semibold))
                    .textSelection(.enabled)
                if !marked, !phonetic.isEmpty {
                    Text(phonetic).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.plan.sourceIsNative {
                    StarButton(saved: vocab.savedKeys.contains(VocabItem.normalize(model.wordTerm))) { model.toggleSaveWord() }
                }
            }
            if let lemma = word.lemma, !lemma.isEmpty, lemma.lowercased() != (word.term ?? "").lowercased() {
                let lemmaPhonetic = word.lemmaPhonetic ?? ""
                Text("原形：\(Phonetic.isMarkedSpelling(lemmaPhonetic, of: lemma) ? lemmaPhonetic : lemma)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let meaning = word.contextMeaning, !meaning.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TagView(text: model.usedContext ? "语境义" : "释义")
                    Text(meaning).font(.system(size: 15, weight: .medium)).textSelection(.enabled)
                }
            }
            if let senses = word.senses, !senses.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(senses, id: \.self) { sense in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(sense.pos ?? "")
                                .font(.system(size: 11.5, weight: .semibold).italic())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(minWidth: 38, alignment: .leading)
                            Text(sense.meaning ?? "").font(.system(size: 13)).textSelection(.enabled)
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
                        Text(src).font(.system(size: 12.5)).italic().textSelection(.enabled)
                        if let t = ex.target, !t.isEmpty { Text(t).font(.system(size: 12)).foregroundStyle(.secondary) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let note = word.note, !note.isEmpty {
                Label { Text(note) } icon: { Image(systemName: "lightbulb").foregroundStyle(Theme.highlight) }
                    .font(.system(size: 12))
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
                    Text(summary).font(.system(size: 12.5)).textSelection(.enabled)
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
                                .font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(model.formsExpanded ? 180 : 0))
                        }
                        .font(.system(size: 11, weight: .semibold))
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
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                if !columns.isEmpty {
                    GridRow {
                        Text("")
                        ForEach(0..<width, id: \.self) { i in
                            Text(i < columns.count ? columns[i] : "")
                                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(0..<width, id: \.self) { i in
                            let cells = row.cells ?? []
                            Text(i < cells.count ? cells[i] : "").font(.system(size: 12.5))
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
                Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                Text("重点表达")
                if let n = model.keyItems?.items?.count, model.keyItemsPhase == .done {
                    Text("\(n)").font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                }
                if model.keyItemsPhase == .loading {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(model.capsuleExpanded ? 180 : 0))
            }
            .font(.system(size: 11.5, weight: .semibold))
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
                    .font(.system(size: 10, weight: .bold))
                Text(model.analysis == nil ? "解析句子" : "收起解析")
                if model.analysis == nil, let hint = model.keyItems?.analysisHint, !hint.isEmpty {
                    Text("· \(hint)").lineLimit(1).foregroundStyle(Theme.accent.opacity(0.75))
                }
            }
            .font(.system(size: 11.5, weight: .semibold))
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
                    .font(.system(size: 12)).foregroundStyle(.secondary)
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
                    Text(item.text).font(.system(size: 13.5, weight: .semibold)).textSelection(.enabled)
                    TagView(text: item.kindLabel, color: Color(red: 0.75, green: 0.52, blue: 0.0))
                    if let p = item.phonetic, !p.isEmpty {
                        Text(p).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let m = item.meaning, !m.isEmpty {
                    Text(m).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85))
                }
                if let n = item.note, !n.isEmpty {
                    Text(n).font(.system(size: 11.5)).foregroundStyle(.secondary)
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
                .font(.system(size: 13))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)

            if let skeleton = analysis.skeleton, !skeleton.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("主干").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    Text(skeleton).font(.system(size: 13.5, weight: .semibold)).textSelection(.enabled)
                    if let t = analysis.skeletonTranslation, !t.isEmpty {
                        Text(t).font(.system(size: 12)).foregroundStyle(.secondary)
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
                                Text(chunk.text ?? "").font(.system(size: 12.5, weight: .medium)).textSelection(.enabled)
                                if let e = chunk.explain, !e.isEmpty {
                                    Text(e).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let usage = analysis.usage, !usage.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("语境与语气").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    Text(usage).font(.system(size: 12.5)).textSelection(.enabled)
                }
            }

            if let insights = analysis.insights, !insights.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(insights, id: \.self) { s in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "lightbulb.fill").font(.system(size: 9)).foregroundStyle(Theme.highlight)
                            Text(s).font(.system(size: 12.5))
                        }
                    }
                }
            }

            if let p = analysis.paraphrase, !p.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("换个说法").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    Text(p).font(.system(size: 12.5)).italic().textSelection(.enabled)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if showSettings {
                    Button("打开设置") {
                        PopupController.shared.close()
                        WindowManager.shared.showSettings(tab: .providers)
                    }
                } else {
                    Button("重试", action: retry)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.accent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
