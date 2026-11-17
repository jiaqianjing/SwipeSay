import SwiftUI

struct ProvidersPane: View {
    @EnvironmentObject private var store: ProviderStore
    @EnvironmentObject private var auth: ChatGPTAuth
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("模型服务").font(.system(size: 20, weight: .semibold))
                    .padding(.top, 34).padding(.horizontal, 16).padding(.bottom, 12)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.providers) { p in
                            ProviderListRow(config: p, active: store.active?.id == p.id, selected: selection == p.id)
                                .onTapGesture { selection = p.id }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                Divider()
                Menu {
                    ForEach(ProviderKind.allCases) { kind in
                        Button(kind.displayName) { selection = store.add(kind).id }
                    }
                } label: {
                    Label("添加服务", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(10)
            }
            .frame(width: 190)

            Divider()

            if let id = selection ?? store.active?.id ?? store.providers.first?.id,
               let config = store.providers.first(where: { $0.id == id }) {
                ProviderDetailView(config: config)
                    .id(config.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer()
            }
        }
    }
}

private struct ProviderListRow: View {
    var config: ProviderConfig
    var active: Bool
    var selected: Bool
    @EnvironmentObject private var auth: ChatGPTAuth

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: config.kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(config.isReady ? config.model : "未配置")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if active {
                Text("默认").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            } else if config.isReady {
                Circle().fill(Color.green).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}

struct ProviderDetailView: View {
    @EnvironmentObject private var store: ProviderStore
    @EnvironmentObject private var auth: ChatGPTAuth

    @State var config: ProviderConfig
    @State private var apiKey = ""
    @State private var fetchedModels: [ModelInfo] = []
    /// 显示全部模型: skip the catalog's filters (non-chat models, dated snapshots, deprecated models).
    @State private var showAllModels = false
    @State private var fetching = false
    /// Quiet one-line status under the model field ("12 models · 0.35 s" or why fetching failed).
    @State private var modelNote: ModelNote?
    @State private var testState: TestState = .idle
    @State private var confirmDelete = false

    /// Result text plus a timing line ("首字 0.31 s · 总计 1.1 s") shown underneath in small grey type.
    enum TestState: Equatable { case idle, running, success(String, timing: String), failure(String, timing: String) }
    struct ModelNote: Equatable { var text: String; var isError: Bool }

    /// Providers already tested in this app session. The first test also pays for DNS and TLS setup, so it's labelled.
    @MainActor private static var warmedUp: Set<UUID> = []

    /// Whether we have what a request needs. Computed from view state, not the keychain, so it updates as you type.
    private var hasCredentials: Bool {
        switch config.kind {
        case .chatGPT: return auth.isSignedIn
        case .openAICompatible: return !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        default: return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canTest: Bool {
        hasCredentials && !config.model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: config.kind.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 36, height: 36)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("名称", text: $config.name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .semibold))
                        Text(config.kind.displayName).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.active?.id == config.id {
                        Label("默认服务", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent)
                    } else {
                        Button("设为默认") {
                            persistKey()
                            store.activeID = config.id
                        }
                        .controlSize(.small)
                        .disabled(!canTest)
                    }
                }
                .padding(.top, 34)

                if config.kind == .chatGPT {
                    ChatGPTLoginCard()
                }

                SettingsCard(header: "连接") {
                    if config.kind != .chatGPT {
                        FieldRow(title: "API Key", subtitle: config.kind == .openAICompatible ? "本地服务（如 Ollama）可留空" : "保存在钥匙串中") {
                            SecureField("sk-…", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                                .onSubmit { persistKey() }
                        }
                        Divider()
                    }
                    FieldRow(title: "Base URL", subtitle: baseURLHint) {
                        TextField(config.kind.defaultBaseURL, text: $config.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                    }
                    Divider()
                    FieldRow(title: "模型") {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                TextField("模型 ID", text: $config.model)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)
                                Menu {
                                    let list = modelList
                                    ForEach(list.pinned, id: \.id) { m in modelButton(m) }
                                    if !list.pinned.isEmpty && !list.others.isEmpty { Divider() }
                                    ForEach(list.others, id: \.id) { m in modelButton(m) }
                                    if !fetchedModels.isEmpty {
                                        Divider()
                                        Toggle("显示全部模型", isOn: $showAllModels)
                                    }
                                    Divider()
                                    Button("从服务获取模型列表") { Task { await fetchModels() } }
                                        .disabled(!hasCredentials)
                                    if (list.pinned + list.others).contains(where: { price(of: $0.id) != nil }) {
                                        Divider()
                                        Text("价格为每百万 token 输入 / 输出（美元），参考价，以官网为准")
                                    }
                                } label: {
                                    if fetching { ProgressView().controlSize(.small) } else { Image(systemName: "list.bullet") }
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            let list = modelList
                            if let modelNote = unlistedModelNote ?? modelNote {
                                let hidden = modelNote.isError ? 0 : list.hidden
                                let what = showAllModels ? "已弃用" : "非对话、旧版本或已弃用"
                                Text(modelNote.text + (hidden > 0 ? " · 已隐藏 \(hidden) 个\(what)模型" : ""))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(modelNote.isError ? Color.orange : Color.secondary)
                                    .lineLimit(2)
                            }
                            if list.selectedDeprecated {
                                Label("当前模型已弃用，建议换用列表中的推荐模型", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                            if let price = price(of: config.model) {
                                Text("参考价 \(price.label) / 百万 token（输入 / 输出），以官网为准")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        runTest()
                    } label: {
                        Label("测试连接", systemImage: "bolt.horizontal")
                    }
                    .disabled(testState == .running || !canTest)
                    switch testState {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case .success(let s, let timing):
                        TestResultLabel(text: s, timing: timing, symbol: "checkmark.circle.fill", color: .green, lines: 2)
                    case .failure(let s, let timing):
                        TestResultLabel(text: s, timing: timing, symbol: "xmark.octagon.fill", color: .red, lines: 3)
                    }
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("删除此服务")
                        .disabled(store.providers.count <= 1)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .onAppear {
            apiKey = config.apiKey ?? ""
            #if DEBUG
            // `-SwipeSayDemoRunTest YES` (mock mode) presses 测试连接 once the pane opens, for screenshots.
            if MockClient.isEnabled, UserDefaults.standard.bool(forKey: "SwipeSayDemoRunTest") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { runTest() }
            }
            #endif
        }
        .onDisappear { persistKey() }
        .onChange(of: config) { _, new in store.update(new) }
        // Typing pauses for 0.6 s → save the key once and refresh the model list. Changing the key or the
        // Base URL again cancels the pending run, so a half-pasted key never gets used. Signing in to or out
        // of ChatGPT changes `hasCredentials`, which reruns this too.
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
        .confirmationDialog("删除「\(config.name)」？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { store.remove(config.id) }
        }
    }

    /// ChatGPT's catalog is per account, so a typed model missing from the fetched list will likely be rejected.
    private var unlistedModelNote: ModelNote? {
        let model = config.model.trimmingCharacters(in: .whitespaces)
        guard config.kind == .chatGPT, !fetchedModels.isEmpty, !model.isEmpty, !fetchedModels.contains(where: { $0.id == model }) else {
            return nil
        }
        return ModelNote(text: "「\(model)」不在此账号的可用模型列表中，可能无法使用", isError: true)
    }

    private var baseURLHint: String? {
        switch config.kind {
        case .openAICompatible: return "OpenRouter、Moonshot、通义、智谱、Ollama 等兼容 /chat/completions 的服务"
        case .chatGPT: return "通常无需修改"
        default: return nil
        }
    }

    /// What the model menu shows: the fetched list, or the provider's suggestions before a fetch.
    private var modelList: ModelCatalog.Arranged {
        let models = fetchedModels.isEmpty ? config.kind.suggestedModels.map { ModelInfo(id: $0) } : fetchedModels
        return ModelCatalog.arrange(models, kind: config.kind, selected: config.model, showAll: showAllModels)
    }

    private func price(of model: String) -> ModelPrice? {
        ModelCatalog.price(for: model, kind: config.kind)
    }

    private func modelButton(_ model: ModelInfo) -> some View {
        var title = model.id
        if model.deprecated { title += "  ·  已弃用" } else if let price = price(of: model.id) { title += "  ·  \(price.label)" }
        return Button(title) { config.model = model.id }
    }

    /// Writes the typed key to the keychain if it changed, and refreshes the provider list's ready state.
    private func persistKey() {
        guard config.kind != .chatGPT else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key != (config.apiKey ?? "") else { return }
        config.apiKey = key.isEmpty ? nil : key
        // The key lives in the keychain, not in `config`, so tell list rows and `active` to re-read it.
        store.objectWillChange.send()
    }

    private func fetchModels() async {
        persistKey()
        fetching = true
        defer { fetching = false }
        let started = ContinuousClock.now
        do {
            let models = try await LLMClientFactory.make(config).listModels()
            guard !Task.isCancelled else { return }
            fetchedModels = models
            modelNote = ModelNote(text: "已获取 \(models.count) 个模型 · \(Self.format(ContinuousClock.now - started))",
                                  isError: false)
        } catch {
            guard !Task.isCancelled else { return }
            // ChatGPT's catalog endpoint isn't a public API; the menu falls back to the built-in suggestions.
            let fallback = config.kind == .chatGPT && fetchedModels.isEmpty ? "，已显示内置列表" : ""
            modelNote = ModelNote(text: "无法获取模型列表\(fallback)：\(error.localizedDescription)", isError: true)
        }
    }

    private func runTest() {
        persistKey()
        testState = .running
        let client = LLMClientFactory.make(config)
        let id = config.id
        let cold = !Self.warmedUp.contains(id)
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
                let total = clock.now - started
                Self.warmedUp.insert(id)
                var timing = "首字 \(Self.format((firstChunk ?? clock.now) - started)) · 总计 \(Self.format(total))"
                if cold { timing += "（首次含建连）" }
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
                testState = .success("成功：\(text)", timing: timing)
            } catch {
                testState = .failure(error.localizedDescription, timing: "失败前用时 \(Self.format(clock.now - started))")
            }
        }
    }

    /// "0.42 s" under a second, "1.3 s" above.
    static func format(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return s < 1 ? String(format: "%.2f s", s) : String(format: "%.1f s", s)
    }
}

struct ChatGPTLoginCard: View {
    @EnvironmentObject private var auth: ChatGPTAuth

    var body: some View {
        SettingsCard(header: "ChatGPT 账号") {
            VStack(alignment: .leading, spacing: 10) {
                switch auth.status {
                case .signedIn(let email, let plan):
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(email ?? "已登录").font(.system(size: 13, weight: .medium))
                            if let plan { Text("套餐：\(plan.capitalized)").font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("退出登录") { auth.signOut() }.controlSize(.small)
                    }
                case .signingIn:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("已在浏览器中打开登录页面，完成后会自动返回…").font(.system(size: 12))
                        Spacer()
                        Button("取消") { auth.cancelSignIn() }.controlSize(.small)
                    }
                case .signedOut, .failed:
                    if case .failed(let msg) = auth.status {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5)).foregroundStyle(.orange)
                    }
                    Text("使用 ChatGPT Plus / Pro / Team 订阅额度，无需 API Key。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            Task { await auth.signIn() }
                        } label: {
                            Label("用 ChatGPT 登录", systemImage: "person.crop.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        Button("导入 Codex CLI 登录") { _ = auth.importFromCodexCLI() }
                    }
                }
                Text("通过 Codex 的官方登录流程授权（OAuth，本机回调端口 1455）。该接口并非公开文档 API，未来可能变动。")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10)
        }
    }
}

/// Label above a full-width field — fits the narrow detail column.
struct FieldRow<Field: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            field
        }
        .padding(.vertical, 9)
    }
}

/// 测试连接 result: an icon and message, with the timing on its own line so the message isn't cut off.
private struct TestResultLabel: View {
    var text: String
    var timing: String
    var symbol: String
    var color: Color
    var lines: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).foregroundStyle(color).lineLimit(lines)
                Text(timing).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.system(size: 12))
    }
}
