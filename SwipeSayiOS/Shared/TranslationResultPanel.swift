import SwiftUI
import SwipeSayKit

/// The translation result on iOS: source quote, translation or word card, the 重点表达 capsule and the follow-up
/// conversation. Used by the app's 翻译 tab and by the action extension.
struct TranslationResultPanel: View {
    @ObservedObject var model: PopupViewModel
    /// The app's 翻译 tab already shows the source in its input box.
    var showsSource = true

    @EnvironmentObject private var vocab: VocabularyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsSource, model.phase != .idle, model.plan.mode == .sentence || model.word == nil {
                sourceQuote
            }
            if model.phase != .idle, model.usedContext {
                Label("已结合所在段落理解", systemImage: "text.alignleft")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            result
            if model.canShowCapsule {
                CapsuleSection(model: model)
            }
            if !model.followUps.isEmpty {
                FollowUpConversation(model: model)
            }
            if model.phase == .done {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceQuote: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent.opacity(0.75)).frame(width: 3)
            Text(highlightedSource)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(model.sourceExpanded ? nil : 5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture { model.sourceExpanded.toggle() }
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

    @ViewBuilder private var result: some View {
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
                    .font(.title3)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label(model.providerLabel.isEmpty ? "未配置模型" : model.providerLabel, systemImage: "cpu")
                .lineLimit(1)
            if let cachedAt = model.cachedAt {
                Text("⚡ 来自缓存 · \(TranslationCachePolicy.age(since: cachedAt))").lineLimit(1)
            }
            Spacer()
            if model.cachedAt != nil {
                Button { model.retranslate() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("重新翻译")
            }
            Button { Speaker.speak(model.learningSentence) } label: { Image(systemName: "speaker.wave.2") }
                .accessibilityLabel("朗读")
            Button { Clipboard.copy(model.translation) } label: { Image(systemName: "doc.on.doc") }
                .accessibilityLabel("复制译文")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .buttonStyle(.borderless)
        .tint(Theme.accent)
    }
}

/// Text box for follow-up questions, pinned above the keyboard.
struct FollowUpBar: View {
    @ObservedObject var model: PopupViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("追问这段内容…", text: $model.followUpDraft, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { model.sendFollowUp() }
            Button { model.sendFollowUp() } label: {
                Image(systemName: model.isFollowUpBusy ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .foregroundStyle(model.canSendFollowUp ? Theme.accent : Color.secondary.opacity(0.45))
            .disabled(!model.canSendFollowUp)
            .accessibilityLabel("发送追问")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}
