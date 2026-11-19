import SwiftUI
import SwipeSayKit

/// 翻译 tab: type or paste text, get the same result the Mac popup shows, and ask follow-ups.
struct TranslateScreen: View {
    @StateObject private var model = PopupViewModel(captured: CapturedText(text: "", origin: .manual), inputMode: true)
    @EnvironmentObject private var providers: ProviderStore
    @Environment(\.openProviderSettings) private var openProviderSettings
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var canTranslate: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasProvider: Bool { providers.active?.isReady == true || isMock }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !hasProvider { setupCard }
                    inputCard
                    if model.phase != .idle {
                        TranslationResultPanel(model: model, showsSource: false)
                            .padding(16)
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        tips
                    }
                }
                .padding(16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("SwipeSay")
            .safeAreaInset(edge: .bottom) {
                if model.canFollowUp {
                    FollowUpBar(model: model).frame(maxWidth: 720)
                }
            }
            .aiConsentGate(model)
            #if DEBUG
            .onAppear(perform: runDemoIfRequested)
            #endif
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("输入或粘贴要翻译的内容", text: $draft, axis: .vertical)
                .font(.body)
                .lineLimit(3...10)
                .focused($inputFocused)
                .submitLabel(.go)
                .onSubmit(translate)
            HStack(spacing: 12) {
                // PasteButton reads the clipboard without the "allow paste" prompt.
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in
                        draft = text
                        translate()
                    }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                if !draft.isEmpty {
                    Button("清空", systemImage: "xmark.circle.fill") {
                        draft = ""
                        model.cancelAll()
                        model.phase = .idle
                        inputFocused = true
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: translate) {
                    Label("翻译", systemImage: "arrow.right.circle.fill")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(!canTranslate || model.phase.isBusy)
            }
            .controlSize(.regular)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("先配置一个模型服务", systemImage: "key.fill").font(.headline)
            Text("SwipeSay 使用你自己的 API Key（OpenAI、Anthropic、Gemini、DeepSeek 或任意 OpenAI 兼容服务）。Key 只保存在本机钥匙串里。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("去设置") { openProviderSettings?() }
                .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.highlight.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("在其他 App 里用").font(.headline)
            NavigationLink {
                SafariGuideScreen()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "safari").foregroundStyle(Theme.accent).frame(width: 22)
                    Text("打开 **Safari 扩展**后，在网页上选中文字，翻译直接出现在下方。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            tip("hand.tap", "在其他 App 里选中文字，点「分享…」，再点 **SwipeSay 翻译**。")
            tip("text.word.spacing", "选中单词或短语会得到单词卡，并自动加入生词本。")
            tip("bubble.left.and.text.bubble.right", "翻译完成后，可以在底部继续追问。")
        }
        .padding(.horizontal, 4)
    }

    private func tip(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func translate() {
        guard canTranslate else { return }
        inputFocused = false
        model.sourceText = draft
        model.submitInput()
    }

    private var isMock: Bool {
        #if DEBUG
        return MockClient.isEnabled
        #else
        return false
        #endif
    }

    #if DEBUG
    /// `-SwipeSayDemo "text"` translates that text on launch (for screenshots). `-SwipeSayDemoExpand YES` also opens
    /// the capsule and the analysis; `-SwipeSayDemoFollowUp <question>` asks a follow-up.
    private func runDemoIfRequested() {
        let defaults = UserDefaults.standard
        // `-SwipeSayDemoConsent YES` (with `-SwipeSayDemoBaseURL <url>`) shows the consent sheet.
        if defaults.bool(forKey: "SwipeSayDemoConsent") { model.needsConsent = true }
        guard model.phase == .idle, let text = defaults.string(forKey: "SwipeSayDemo") else { return }
        draft = text
        translate()
        let model = self.model
        if let question = defaults.string(forKey: "SwipeSayDemoFollowUp") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                model.followUpDraft = question
                model.sendFollowUp()
            }
        }
        guard defaults.bool(forKey: "SwipeSayDemoExpand") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            model.toggleCapsule()
            model.formsExpanded = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) { model.loadAnalysis() }
    }
    #endif
}
