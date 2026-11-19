import SwiftUI
import SwipeSayKit

/// Edit one provider: key, base URL, model, and a connection test. Mirrors the Mac `ProviderDetailView`
/// without the ChatGPT sign-in.
struct ProviderEditor: View {
    @EnvironmentObject private var store: ProviderStore
    @Environment(\.dismiss) private var dismiss

    @State var config: ProviderConfig
    @State private var apiKey = ""
    @State private var fetchedModels: [ModelInfo] = []
    @State private var showAllModels = false
    @State private var fetching = false
    @State private var modelNote: (text: String, isError: Bool)?
    @State private var testState: TestState = .idle
    @State private var confirmDelete = false

    enum TestState: Equatable {
        case idle, running
        case success(String, timing: String)
        case failure(String, timing: String)
    }

    private var hasCredentials: Bool {
        switch config.kind {
        case .openAICompatible: return !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        default: return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canTest: Bool { hasCredentials && !config.model.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isActive: Bool { store.active?.id == config.id }

    private var modelList: ModelCatalog.Arranged {
        let models = fetchedModels.isEmpty ? config.kind.suggestedModels.map { ModelInfo(id: $0) } : fetchedModels
        return ModelCatalog.arrange(models, kind: config.kind, selected: config.model, showAll: showAllModels)
    }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $config.name)
                if config.kind.usesAPIKey {
                    SecureField(config.kind.needsAPIKey ? "API Key" : "API Key（可选）", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField(config.kind.defaultBaseURL, text: $config.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(config.kind.displayName)
            } footer: {
                if config.kind == .openAICompatible {
                    Text("OpenRouter、Moonshot、通义、智谱、Ollama 等兼容 /chat/completions 的服务。")
                }
            }

            Section {
                TextField("模型 ID", text: $config.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Menu {
                    ForEach(modelList.pinned, id: \.id) { modelButton($0) }
                    if !modelList.pinned.isEmpty && !modelList.others.isEmpty { Divider() }
                    ForEach(modelList.others, id: \.id) { modelButton($0) }
                } label: {
                    Label(fetching ? "正在获取模型列表…" : "选择模型", systemImage: "list.bullet")
                }
                Toggle("显示全部模型", isOn: $showAllModels)
            } header: {
                Text("模型")
            } footer: {
                if let modelNote {
                    Text(modelNote.text).foregroundStyle(modelNote.isError ? .red : .secondary)
                } else if let price = ModelCatalog.price(for: config.model, kind: config.kind) {
                    Text("参考价格：\(price.label)")
                }
            }

            Section {
                Button {
                    runTest()
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        if testState == .running { ProgressView() }
                    }
                }
                .disabled(!canTest || testState == .running)
                testResult
            }

            Section {
                if isActive && config.isReady {
                    Label("当前正在使用", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                } else {
                    Button("设为当前使用") {
                        persistKey()
                        store.activeID = config.id
                    }
                    .disabled(!canTest)
                }
            }

            Section {
                Button("删除此服务", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(config.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { apiKey = config.apiKey ?? "" }
        .onDisappear { persistKey() }
        .onChange(of: config) { _, new in store.update(new) }
        // Typing pauses → save the key once and refresh the model list.
        .task(id: "\(apiKey)|\(config.baseURL)|\(hasCredentials)") {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            persistKey()
            guard hasCredentials else {
                fetchedModels = []
                modelNote = nil
                return
            }
            await fetchModels()
        }
        .confirmationDialog("删除「\(config.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.remove(config.id)
                dismiss()
            }
        }
    }

    @ViewBuilder private var testResult: some View {
        switch testState {
        case .idle, .running:
            EmptyView()
        case .success(let text, let timing):
            VStack(alignment: .leading, spacing: 2) {
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(timing).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .failure(let text, let timing):
            VStack(alignment: .leading, spacing: 2) {
                Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(4)
                Text(timing).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func modelButton(_ model: ModelInfo) -> some View {
        var title = model.id
        if model.deprecated {
            title += "  ·  已弃用"
        } else if let price = ModelCatalog.price(for: model.id, kind: config.kind) {
            title += "  ·  \(price.label)"
        }
        return Button {
            config.model = model.id
        } label: {
            if model.id == config.model { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func persistKey() {
        guard config.kind.usesAPIKey else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != (config.apiKey ?? "") else { return }
        config.apiKey = key.isEmpty ? nil : key
        store.objectWillChange.send()
    }

    private func fetchModels() async {
        fetching = true
        defer { fetching = false }
        let started = ContinuousClock.now
        do {
            let models = try await LLMClientFactory.make(config).listModels()
            guard !Task.isCancelled else { return }
            fetchedModels = models
            modelNote = ("已获取 \(models.count) 个模型 · \(Self.format(ContinuousClock.now - started))", false)
        } catch {
            guard !Task.isCancelled else { return }
            modelNote = ("无法获取模型列表：\(error.localizedDescription)", true)
        }
    }

    /// The test sends a fixed English sentence, never the user's text, so it needs no consent.
    private func runTest() {
        persistKey()
        testState = .running
        let client = LLMClientFactory.make(config)
        Task {
            let clock = ContinuousClock()
            let started = clock.now
            var firstChunk: ContinuousClock.Instant?
            var reply = ""
            do {
                let stream = client.stream(LLMRequest(
                    system: "Translate the user's text into Simplified Chinese. Output only the translation.",
                    user: "It's raining cats and dogs.", maxTokens: 200, kind: .test))
                for try await delta in stream {
                    if firstChunk == nil { firstChunk = clock.now }
                    reply += delta
                }
                let timing = "首字 \(Self.format((firstChunk ?? clock.now) - started)) · 总计 \(Self.format(clock.now - started))"
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
                testState = .success("成功：\(text)", timing: timing)
            } catch {
                testState = .failure(error.localizedDescription, timing: "失败前用时 \(Self.format(clock.now - started))")
            }
        }
    }

    static func format(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return s < 1 ? String(format: "%.2f s", s) : String(format: "%.1f s", s)
    }
}
