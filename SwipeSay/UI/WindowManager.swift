import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, providers, shortcuts, learning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .providers: return "模型服务"
        case .shortcuts: return "快捷键"
        case .learning: return "学习"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "cpu"
        case .shortcuts: return "command"
        case .learning: return "graduationcap"
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
}

@MainActor
final class WindowManager {
    static let shared = WindowManager()

    let settingsNav = SettingsNavigation()
    private var settingsWindow: NSWindow?
    private var vocabularyWindow: NSWindow?

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { settingsNav.tab = tab }
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(settingsNav)
                .environmentObject(AppSettings.shared)
                .environmentObject(ProviderStore.shared)
                .environmentObject(ChatGPTAuth.shared)
            settingsWindow = makeWindow(title: "SwipeSay 设置", size: NSSize(width: 760, height: 540), root: root, resizable: false)
        }
        present(settingsWindow)
    }

    func showVocabulary() {
        if vocabularyWindow == nil {
            let root = VocabularyView()
                .modelContainer(VocabularyStore.shared.container)
                .environmentObject(VocabularyStore.shared)
            vocabularyWindow = makeWindow(title: "生词本", size: NSSize(width: 860, height: 580), root: root, resizable: true)
            vocabularyWindow?.minSize = NSSize(width: 680, height: 420)
        }
        present(vocabularyWindow)
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<V: View>(title: String, size: NSSize, root: V, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: root.tint(Theme.accent))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        return window
    }
}
