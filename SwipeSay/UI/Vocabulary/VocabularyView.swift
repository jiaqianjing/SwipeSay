import SwiftUI
import SwiftData

struct VocabularyView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", due = "待复习", mastered = "已掌握"
        var id: String { rawValue }
    }

    @Query(sort: \VocabItem.createdAt, order: .reverse) private var items: [VocabItem]
    @EnvironmentObject private var store: VocabularyStore
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var selection: PersistentIdentifier?
    @State private var reviewing = false

    private var filtered: [VocabItem] {
        items.filter { item in
            switch filter {
            case .all: break
            case .due: if !item.isDue { return false }
            case .mastered: if !item.isMastered { return false }
            }
            guard !search.isEmpty else { return true }
            return item.term.localizedCaseInsensitiveContains(search) || item.meaning.localizedCaseInsensitiveContains(search)
        }
    }

    private var dueItems: [VocabItem] { items.filter(\.isDue) }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                List(selection: $selection) {
                    ForEach(filtered) { item in
                        VocabRow(item: item).tag(item.persistentModelID)
                            .contextMenu {
                                Button("删除", role: .destructive) { delete(item) }
                            }
                    }
                    .onDelete { offsets in offsets.map { filtered[$0] }.forEach(delete) }
                }
                .modifier(SidebarListStyle())
                .searchable(text: $search, placement: .sidebar, prompt: "搜索单词或释义")
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            #if DEBUG
            // `-SwipeSayDemoSelect <term>` opens that entry, for screenshots.
            .onAppear {
                guard selection == nil, let term = UserDefaults.standard.string(forKey: "SwipeSayDemoSelect") else { return }
                selection = items.first { $0.key == VocabItem.normalize(term) }?.persistentModelID
            }
            #endif
        } detail: {
            if let id = selection, let item = items.first(where: { $0.persistentModelID == id }) {
                VocabDetailView(item: item) { delete(item) }
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("生词本还是空的", systemImage: "book.closed")
                } description: {
                    Text("划词查单词、展开「重点表达」时，SwipeSay 会自动把值得记的词收进来。")
                }
            } else {
                ContentUnavailableView {
                    Label("\(items.count) 个词条", systemImage: "character.book.closed")
                } description: {
                    Text(dueItems.isEmpty ? "今天的复习已完成 🎉" : "有 \(dueItems.count) 个词等待复习")
                } actions: {
                    if !dueItems.isEmpty {
                        Button("开始复习") { reviewing = true }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    reviewing = true
                } label: {
                    Label("复习 \(dueItems.count)", systemImage: "rectangle.stack")
                }
                .disabled(dueItems.isEmpty)
                .help("闪卡复习到期词条")
            }
        }
        .sheet(isPresented: $reviewing) {
            ReviewView(queue: dueItems.shuffled()) { reviewing = false }
        }
    }

    private func delete(_ item: VocabItem) {
        if selection == item.persistentModelID { selection = nil }
        store.delete(item)
    }
}

private struct VocabRow: View {
    var item: VocabItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(item.term).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if item.isDue { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                if item.isMastered { Image(systemName: "checkmark.seal.fill").font(.system(size: 9)).foregroundStyle(.green) }
            }
            Text(item.meaning).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct VocabDetailView: View {
    @Bindable var item: VocabItem
    var onDelete: () -> Void
    @EnvironmentObject private var store: VocabularyStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.term).font(.system(size: 30, weight: .bold)).textSelection(.enabled)
                    if !item.phonetic.isEmpty {
                        Text(item.phonetic).font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    Button { Speaker.speak(item.term) } label: { Image(systemName: "speaker.wave.2.fill") }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                HStack(spacing: 6) {
                    TagView(text: kindLabel)
                    StageDots(stage: item.stage)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.meaning).font(.system(size: 17, weight: .medium)).textSelection(.enabled)
                    if !item.note.isEmpty {
                        Label { Text(item.note) } icon: { Image(systemName: "lightbulb").foregroundStyle(Theme.highlight) }
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }

                if !item.sentence.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("原句").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Text(highlighted(item.sentence, term: item.term))
                            .font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                        if !item.sentenceTranslation.isEmpty {
                            Text(item.sentenceTranslation).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack(spacing: 14) {
                    if !item.sourceApp.isEmpty { Label(item.sourceApp, systemImage: "app") }
                    Label(item.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    Label("复习 \(item.reviewCount) 次", systemImage: "arrow.triangle.2.circlepath")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)

                HStack {
                    Button(item.isMastered ? "重新学习" : "标记为已掌握") {
                        item.stage = item.isMastered ? 0 : VocabItem.intervals.count
                        item.nextReview = Date()
                        store.save()
                    }
                    Spacer()
                    Button("删除", role: .destructive, action: onDelete)
                }
                .controlSize(.small)
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private var kindLabel: String {
        KeyItem(text: item.term, kind: item.kind).kindLabel
    }

    private func highlighted(_ sentence: String, term: String) -> AttributedString {
        var attributed = AttributedString(sentence)
        if let range = attributed.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].backgroundColor = Theme.highlight.opacity(0.4)
            attributed[range].font = .system(size: 14, weight: .semibold)
        }
        return attributed
    }
}

private struct StageDots: View {
    var stage: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<VocabItem.intervals.count, id: \.self) { i in
                Circle().fill(i < stage ? Theme.accent : Color.primary.opacity(0.12)).frame(width: 6, height: 6)
            }
        }
        .help("记忆阶段 \(min(stage, VocabItem.intervals.count))/\(VocabItem.intervals.count)")
    }
}

// MARK: - Review

struct ReviewView: View {
    var queue: [VocabItem]
    var onClose: () -> Void
    @EnvironmentObject private var store: VocabularyStore
    @State private var index = 0
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("复习").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(min(index + 1, queue.count)) / \(queue.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("完成", action: onClose).padding(.leading, 8)
            }
            .padding(16)

            ProgressView(value: Double(index), total: Double(max(queue.count, 1)))
                .tint(Theme.accent)
                .padding(.horizontal, 16)

            if index < queue.count {
                let item = queue[index]
                VStack(spacing: 16) {
                    Spacer()
                    Text(item.term).font(.system(size: 34, weight: .bold))
                    if !item.phonetic.isEmpty { Text(item.phonetic).foregroundStyle(.secondary) }
                    if !item.sentence.isEmpty {
                        Text(item.sentence)
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                    }
                    if revealed {
                        VStack(spacing: 6) {
                            Text(item.meaning).font(.system(size: 18, weight: .medium))
                            if !item.sentenceTranslation.isEmpty {
                                Text(item.sentenceTranslation).font(.system(size: 13)).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center).padding(.horizontal, 30)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    Spacer()
                    if revealed {
                        HStack(spacing: 12) {
                            gradeButton("忘记了", .forgot, color: .red, key: "1")
                            gradeButton("有点模糊", .fuzzy, color: .orange, key: "2")
                            gradeButton("记得", .known, color: .green, key: "3")
                        }
                    } else {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { revealed = true }
                        } label: {
                            Text("显示释义").frame(width: 200)
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                        .keyboardShortcut(.space, modifiers: [])
                    }
                }
                .padding(24)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Text("🎉").font(.system(size: 48))
                    Text("本轮复习完成").font(.system(size: 18, weight: .semibold))
                    Button("关闭", action: onClose).buttonStyle(.borderedProminent).tint(Theme.accent)
                    Spacer()
                }
            }
        }
        .frame(width: 520, height: 440)
    }

    private func gradeButton(_ title: String, _ grade: VocabItem.Grade, color: Color, key: KeyEquivalent) -> some View {
        Button {
            queue[index].review(grade)
            store.save()
            revealed = false
            withAnimation { index += 1 }
        } label: {
            Text(title).frame(width: 110)
        }
        .controlSize(.large)
        .tint(color)
        .keyboardShortcut(key, modifiers: [])
    }
}

/// Sidebar list style, except under Debug `-SwipeSayFlatBackground YES`. In-app snapshots can't draw the
/// sidebar's vibrant text and selection, so that mode uses the plain inset style instead.
private struct SidebarListStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "SwipeSayFlatBackground") {
            return AnyView(content.listStyle(.inset))
        }
        #endif
        return AnyView(content.listStyle(.sidebar))
    }
}
