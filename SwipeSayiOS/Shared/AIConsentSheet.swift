import SwiftUI
import SwipeSayKit

enum AppLinks {
    static let privacyPolicy = URL(string: "https://github.com/jiaqianjing/SwipeSay/blob/main/docs/privacy.md")!
}

/// Asks before any text goes to a third-party AI service (App Review guideline 5.1.2(i)).
/// Names the service and the host, says what is sent, and records consent per provider and host.
struct AIConsentSheet: View {
    var config: ProviderConfig
    var onAgree: () -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.accent)
                    Text("把文字发送给「\(config.name)」？")
                        .font(.title2.bold())
                    VStack(alignment: .leading, spacing: 12) {
                        point("arrow.up.right", "SwipeSay 会把你要翻译的文字直接发送到 **\(config.endpointHost)**，由 \(config.name) 的模型生成译文、单词卡和解析。")
                        point("text.alignleft", "在 Safari 中使用时，还会附带所选文字所在的段落，帮助模型理解上下文。你的追问内容也会一并发送。")
                        point("lock.shield", "SwipeSay 没有自己的服务器，不收集、不保存这些内容。生词本和缓存只保存在你的设备上。")
                        point("doc.text", "\(config.name) 如何处理这些数据，以它自己的隐私政策和服务条款为准。")
                    }
                    Link("SwipeSay 隐私政策", destination: AppLinks.privacyPolicy)
                        .font(.footnote)
                    Text("可以随时在 设置 › 隐私 中撤回。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button(action: onAgree) {
                        Text("同意并继续").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("暂不", role: .cancel, action: onCancel)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .background(.bar)
            }
        }
        .tint(Theme.accent)
        .presentationDetents([.large])
        .interactiveDismissDisabled()
    }

    private func point(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// Shows `AIConsentSheet` whenever `model` stopped because the active provider needs consent, then retries.
    func aiConsentGate(_ model: PopupViewModel) -> some View {
        modifier(AIConsentGate(model: model))
    }
}

private struct AIConsentGate: ViewModifier {
    @ObservedObject var model: PopupViewModel

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { model.needsConsent }, set: { if !$0 { model.needsConsent = false } })) {
            if let config = ProviderStore.shared.active {
                AIConsentSheet(config: config) {
                    AppSettings.shared.grantAIConsent(for: config)
                    model.needsConsent = false
                    model.translate()
                } onCancel: {
                    model.needsConsent = false
                }
            }
        }
    }
}
