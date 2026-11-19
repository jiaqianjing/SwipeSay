import UIKit
import SwipeSayKit
import SwiftUI
import UniformTypeIdentifiers

/// "SwipeSay 翻译" in the share sheet. Receives selected text (any app) or, from Safari's toolbar, the page's
/// selection plus its surrounding paragraph via GetSelection.js, and shows the same result as the app.
final class ActionViewController: UIViewController {
    private let state = ActionState()

    override func viewDidLoad() {
        super.viewDidLoad()
        let root = ActionRootView(state: state) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        .environmentObject(VocabularyStore.shared)
        .tint(Theme.accent)
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        Task { await loadInput() }
    }

    private func loadInput() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        // Safari toolbar: the JavaScript preprocessing result (selection + paragraph + title).
        let jsType = UTType.propertyList.identifier
        for provider in providers where provider.hasItemConformingToTypeIdentifier(jsType) {
            if let dict = try? await provider.loadItem(forTypeIdentifier: jsType) as? NSDictionary,
               let results = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                let text = (results["selection"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    await state.start(CapturedText(text: text, context: results["context"] as? String,
                                                   appName: "Safari", windowTitle: results["title"] as? String,
                                                   origin: .selection))
                    return
                }
                await state.fail("请先在网页上选中要翻译的文字，再点「SwipeSay 翻译」。")
                return
            }
        }
        // Any app: selected text shared as plain text.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await state.start(CapturedText(text: text, origin: .selection))
                return
            }
        }
        await state.fail("没有收到可翻译的文字。")
    }
}

@MainActor
final class ActionState: ObservableObject {
    @Published var model: PopupViewModel?
    @Published var message: String?

    func start(_ captured: CapturedText) {
        let model = PopupViewModel(captured: captured)
        self.model = model
        model.start()
    }

    func fail(_ message: String) { self.message = message }
}

struct ActionRootView: View {
    @ObservedObject var state: ActionState
    var done: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let model = state.model {
                    ActionResultView(model: model)
                } else if let message = state.message {
                    ContentUnavailableView("无法翻译", systemImage: "text.badge.xmark", description: Text(message))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("SwipeSay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成", action: done) }
            }
        }
    }
}

private struct ActionResultView: View {
    @ObservedObject var model: PopupViewModel

    var body: some View {
        ScrollView {
            TranslationResultPanel(model: model)
                .padding(16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if model.canFollowUp { FollowUpBar(model: model).frame(maxWidth: 720) }
        }
        .aiConsentGate(model)
    }
}
