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
    @State private var fetchedModels: [String] = []
    @State private var fetching = false
    @State private var testState: TestState = .idle
    @State private var confirmDelete = false

    enum TestState: Equatable { case idle, running, success(String), failure(String) }

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
                        Button("设为默认") { store.activeID = config.id }
                            .controlSize(.small)
                            .disabled(!config.isReady)
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
                                .onSubmit { config.apiKey = apiKey }
                                .onChange(of: apiKey) { _, new in config.apiKey = new }
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
                        HStack(spacing: 6) {
                            TextField("模型 ID", text: $config.model)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            Menu {
                                let models = fetchedModels.isEmpty ? config.kind.suggestedModels : fetchedModels
                                ForEach(models, id: \.self) { m in Button(m) { config.model = m } }
                                if config.kind != .chatGPT {
                                    Divider()
                                    Button("从服务获取模型列表") { fetchModels() }
                                }
                            } label: {
                                if fetching { ProgressView().controlSize(.small) } else { Image(systemName: "list.bullet") }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        runTest()
                    } label: {
                        Label("测试连接", systemImage: "bolt.horizontal")
                    }
                    .disabled(testState == .running || !config.isReady)
                    switch testState {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case .success(let s):
                        Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12)).lineLimit(2)
                    case .failure(let s):
                        Label(s, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.system(size: 12)).lineLimit(3)
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
        .onAppear { apiKey = config.apiKey ?? "" }
        .onChange(of: config) { _, new in store.update(new) }
        .confirmationDialog("删除「\(config.name)」？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { store.remove(config.id) }
        }
    }

    private var baseURLHint: String? {
        switch config.kind {
        case .openAICompatible: return "OpenRouter、Moonshot、通义、智谱、Ollama 等兼容 /chat/completions 的服务"
        case .chatGPT: return "通常无需修改"
        default: return nil
        }
    }

    private func fetchModels() {
        fetching = true
        Task {
            defer { fetching = false }
            do {
                fetchedModels = try await LLMClientFactory.make(config).listModels()
                testState = .success("获取到 \(fetchedModels.count) 个模型")
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }

    private func runTest() {
        testState = .running
        let client = LLMClientFactory.make(config)
        Task {
            do {
                let reply = try await client.complete(LLMRequest(
                    system: "Translate the user's text into Simplified Chinese. Output only the translation.",
                    user: "It's raining cats and dogs.", maxTokens: 200))
                testState = .success("成功：\(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))")
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
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
