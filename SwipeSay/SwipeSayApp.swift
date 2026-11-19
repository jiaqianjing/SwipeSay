import SwiftUI
import SwipeSayKit

@main
struct SwipeSayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(settings)
        } label: {
            Image(systemName: "highlighter")
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if let version = updater.pendingUpdateVersion {
            Button("安装更新 \(version)…") { updater.checkForUpdates() }
            Divider()
        }
        Button("划词翻译\t\(settings.selectionShortcut.displayString)") { AppDelegate.shared?.translateSelection() }
        Button("截图翻译\t\(settings.screenshotShortcut.displayString)") { AppDelegate.shared?.translateScreenshot() }
        Button("输入翻译\t\(settings.inputShortcut.displayString)") { AppDelegate.shared?.showInput() }
        Divider()
        Button("生词本…") { WindowManager.shared.showVocabulary() }
            .keyboardShortcut("l")
        Button("设置…") { WindowManager.shared.showSettings() }
            .keyboardShortcut(",")
        if Updater.isEnabled {
            Button("检查更新…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        Divider()
        Button("退出 SwipeSay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
