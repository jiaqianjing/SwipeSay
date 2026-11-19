import SwiftUI
import SwipeSayKit
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
            IconButton(systemName: "doc.on.doc", help: "复制译文") { Clipboard.copy(model.translation) }
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
