import SwiftUI
import AVFoundation

struct SettingsScreen: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ProviderStore
    @ObservedObject private var cache = TranslationCache.shared
    @State private var csvURL: URL?
    @State private var confirmClearCache = false

    var body: some View {
        Form {
            providersSection
            Section("翻译") {
                Picker("我的母语", selection: $settings.targetLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("母语内容译成", selection: $settings.secondaryLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("学习水平", selection: $settings.learnerLevel) {
                    ForEach(LearnerLevel.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("结合上下文理解", isOn: $settings.useContext)
            }
            Section {
                Toggle("查单词时自动加入", isOn: $settings.autoAddWords)
                Toggle("重点表达自动加入", isOn: $settings.autoAddKeyItems)
                if let csvURL {
                    ShareLink(item: csvURL) { Label("导出 CSV", systemImage: "square.and.arrow.up") }
                }
            } header: {
                Text("生词本")
            }
            Section {
                NavigationLink("朗读声音") { SpeechVoicesScreen() }
            }
            cacheSection
            Section("隐私") {
                NavigationLink("已允许的模型服务") { ConsentListScreen() }
                Link("隐私政策", destination: AppLinks.privacyPolicy)
            }
            Section {
                LabeledContent("版本", value: Self.version)
            } footer: {
                Text("SwipeSay 没有自己的服务器：文字直接从你的设备发给你选择的模型服务，生词本与缓存只保存在本机。")
            }
        }
        .navigationTitle("设置")
        .task { csvURL = exportCSV() }
    }

    private var providersSection: some View {
        Section {
            ForEach(store.providers) { config in
                NavigationLink {
                    ProviderEditor(config: config)
                } label: {
                    ProviderRow(config: config, isActive: store.active?.id == config.id)
                }
            }
            Menu {
                Button("OpenAI 兼容服务") { _ = store.add(.openAICompatible) }
                ForEach(ProviderKind.available.filter { $0 != .openAICompatible }) { kind in
                    Button(kind.displayName) { _ = store.add(kind) }
                }
            } label: {
                Label("添加服务", systemImage: "plus")
            }
        } header: {
            Text("模型服务")
        } footer: {
            Text("API Key 保存在本机钥匙串中，只在请求对应服务时使用。")
        }
    }

    private var cacheSection: some View {
        Section {
            Toggle("缓存翻译结果", isOn: $settings.cacheEnabled)
            Picker("保留时间", selection: $settings.cacheRetention) {
                ForEach(CacheRetention.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: settings.cacheRetention) { cache.pruneExpired() }
            Picker("占用上限", selection: $settings.cacheSizeLimit) {
                ForEach(CacheSizeLimit.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: settings.cacheSizeLimit) { cache.sizeLimitChanged() }
            Button("清空缓存", role: .destructive) { confirmClearCache = true }
                .confirmationDialog("清空所有缓存的翻译结果？", isPresented: $confirmClearCache, titleVisibility: .visible) {
                    Button("清空", role: .destructive) { cache.clear() }
                }
        } header: {
            Text("缓存")
        } footer: {
            Text("同样的内容再次翻译时直接显示缓存结果，不再请求模型。")
        }
    }

    private func exportCSV() -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "SwipeSay-生词本.csv")
        do {
            try VocabularyStore.shared.exportCSV().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

private struct ProviderRow: View {
    var config: ProviderConfig
    var isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: config.kind.symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                Text(config.isReady ? config.model : "未配置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive && config.isReady {
                Text("使用中").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// Providers the user agreed to send text to, with a way to take that back.
private struct ConsentListScreen: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ProviderStore

    private var consented: [ProviderConfig] { store.providers.filter { settings.hasAIConsent(for: $0) } }

    var body: some View {
        List {
            if consented.isEmpty {
                Text("还没有允许任何服务。第一次使用某个服务翻译时，SwipeSay 会先征求你的同意。")
                    .foregroundStyle(.secondary)
            }
            ForEach(consented) { config in
                HStack {
                    VStack(alignment: .leading) {
                        Text(config.name)
                        Text(config.endpointHost).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("撤回", role: .destructive) { settings.revokeAIConsent(for: config) }
                        .buttonStyle(.borderless)
                }
            }
        }
        .navigationTitle("已允许的模型服务")
    }
}

/// Voice per language for pronunciation; better voices are downloaded in iOS Settings.
private struct SpeechVoicesScreen: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            ForEach(AppLanguage.allCases) { lang in
                Section(lang.displayName) {
                    Picker("声音", selection: binding(for: lang)) {
                        Text("自动（最佳可用）").tag("")
                        ForEach(Speaker.installedVoices(for: lang), id: \.identifier) { voice in
                            Text(Speaker.displayName(voice)).tag(voice.identifier)
                        }
                    }
                    Button("试听") { Speaker.preview(lang) }
                }
            }
            Section {
                Text("更自然的「增强」「高级」声音可在 iPhone 设置 › 辅助功能 › 朗读内容 › 声音 中下载。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("朗读声音")
    }

    private func binding(for lang: AppLanguage) -> Binding<String> {
        Binding(
            get: { settings.speechVoices[lang.rawValue] ?? "" },
            set: { settings.speechVoices[lang.rawValue] = $0.isEmpty ? nil : $0 }
        )
    }
}
