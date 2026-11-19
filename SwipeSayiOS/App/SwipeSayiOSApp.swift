import SwiftUI

@main
struct SwipeSayiOSApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var providers = ProviderStore.shared

    init() {
        #if DEBUG
        // Pass the `-SwipeSayMock YES` launch flag on to the action extension, which gets no launch arguments.
        SharedStorage.defaults.set(UserDefaults.standard.bool(forKey: "SwipeSayMock"), forKey: "SwipeSayMock")
        // `-SwipeSayDemoVocabulary YES` (mock mode only) fills the in-memory vocabulary with sample entries.
        if MockClient.isEnabled, UserDefaults.standard.bool(forKey: "SwipeSayDemoVocabulary") {
            VocabularyStore.shared.seedDemo()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(providers)
                .environmentObject(VocabularyStore.shared)
                .modelContainer(VocabularyStore.shared.container)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case translate, vocabulary, settings }

    @State private var tab: Tab = Self.initialTab
    @State private var settingsPath = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var vocab: VocabularyStore

    var body: some View {
        TabView(selection: $tab) {
            TranslateScreen()
                .tabItem { Label("翻译", systemImage: "character.bubble") }
                .tag(Tab.translate)
            VocabularyView()
                .tabItem { Label("生词本", systemImage: "book") }
                .tag(Tab.vocabulary)
            NavigationStack(path: $settingsPath) {
                SettingsScreen()
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .environment(\.openProviderSettings) {
            tab = .settings
            settingsPath = NavigationPath()
        }
        // `swipesay://settings` (from the Safari extension when no provider is set up) opens 设置.
        .onOpenURL { url in
            guard url.scheme == "swipesay" else { return }
            if url.host == "settings" {
                tab = .settings
                settingsPath = NavigationPath()
            }
        }
        // The action extension writes to the same stores; pick up its additions when coming back.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vocab.reloadKeys() }
        }
    }

    /// `-SwipeSayTab vocabulary|settings` opens on that tab (Debug, for screenshots).
    private static var initialTab: Tab {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "SwipeSayTab") {
        case "vocabulary": return .vocabulary
        case "settings": return .settings
        default: break
        }
        #endif
        return .translate
    }
}
