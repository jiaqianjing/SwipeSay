import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

struct SettingsView: View {
    @EnvironmentObject private var nav: SettingsNavigation

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                    Text("SwipeSay").font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.top, 36)
                .padding(.bottom, 14)
                ForEach(SettingsTab.allCases) { tab in
                    SidebarItem(tab: tab, selected: nav.tab == tab) { nav.tab = tab }
                }
                Spacer()
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(10)
            }
            .padding(.horizontal, 8)
            .frame(width: 180)
            .frame(maxHeight: .infinity)
            .background(VisualEffectBackground(material: .sidebar))

            Divider()

            Group {
                switch nav.tab {
                case .general: GeneralSettingsPane()
                case .providers: ProvidersPane()
                case .shortcuts: ShortcutsPane()
                case .learning: LearningPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        .ignoresSafeArea()
        .tint(Theme.accent)
    }
}

private struct SidebarItem: View {
    var tab: SettingsTab
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: tab.symbol).frame(width: 18)
                Text(tab.title)
                Spacer()
            }
            .font(.system(size: 13))
            .foregroundStyle(selected ? Color.primary : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shared pane chrome.
struct Pane<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.system(size: 20, weight: .semibold)).padding(.top, 34)
                content
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsCard<Content: View>: View {
    var header: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 9)
    }
}

// MARK: - General

struct GeneralSettingsPane: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var axTrusted = SelectionCapture.isTrusted
    @State private var screenGranted = ScreenshotOCR.hasScreenAccess
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Pane(title: "通用") {
            SettingsCard(header: "权限") {
                SettingsRow(title: "辅助功能", subtitle: "读取划选文字和上下文所必需") {
                    PermissionBadge(granted: axTrusted) {
                        SelectionCapture.requestAccessibility()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                Divider()
                SettingsRow(title: "屏幕录制", subtitle: "截图翻译所必需，授权后可能需要重启 SwipeSay") {
                    PermissionBadge(granted: screenGranted) {
                        ScreenshotOCR.requestScreenAccess()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }

            SettingsCard(header: "语言") {
                SettingsRow(title: "我的语言", subtitle: "外语译为此语言，解释也用它书写") {
                    Picker("", selection: $settings.targetLanguage) {
                        ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                }
                Divider()
                SettingsRow(title: "原文是我的语言时译为", subtitle: "例如选中中文时译为英文") {
                    Picker("", selection: $settings.secondaryLanguage) {
                        ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                }
            }

            SettingsCard(header: "行为") {
                SettingsRow(title: "结合上下文翻译", subtitle: "读取选区所在段落，消除多义词与指代歧义") {
                    Toggle("", isOn: $settings.useContext).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                SettingsRow(title: "划词后显示快捷按钮", subtitle: "用鼠标选中文字后，在光标旁出现一个小按钮") {
                    Toggle("", isOn: $settings.showQuickIcon).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                SettingsRow(title: "登录时启动") {
                    Toggle("", isOn: $settings.launchAtLogin).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                SettingsRow(title: "在 Dock 中显示图标") {
                    Toggle("", isOn: $settings.showDockIcon).labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onReceive(timer) { _ in
            axTrusted = SelectionCapture.isTrusted
            screenGranted = ScreenshotOCR.hasScreenAccess
        }
    }
}

struct PermissionBadge: View {
    var granted: Bool
    var action: () -> Void

    var body: some View {
        if granted {
            Label("已授权", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
        } else {
            Button("去授权", action: action).controlSize(.small)
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Pane(title: "快捷键") {
            SettingsCard {
                SettingsRow(title: "划词翻译", subtitle: "翻译当前选中的文字（会结合上下文）") {
                    ShortcutRecorder(shortcut: $settings.selectionShortcut)
                }
                Divider()
                SettingsRow(title: "截图翻译", subtitle: "框选屏幕区域，本地 OCR 后翻译") {
                    ShortcutRecorder(shortcut: $settings.screenshotShortcut)
                }
                Divider()
                SettingsRow(title: "输入翻译", subtitle: "打开输入框，手动输入内容翻译") {
                    ShortcutRecorder(shortcut: $settings.inputShortcut)
                }
            }
            Text("点击快捷键后按下新的组合键（需包含 ⌘、⌥ 或 ⌃），Esc 取消。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "按下快捷键…" : shortcut.displayString)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(minWidth: 96)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(recording ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? Theme.accent : .clear))
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotkeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            if let new = Shortcut(event: event) {
                shortcut = new
                stop()
                return nil
            }
            NSSound.beep()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotkeyManager.shared.resume() }
        recording = false
    }
}

// MARK: - Learning

struct LearningPane: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Pane(title: "学习") {
            SettingsCard(header: "重点表达") {
                SettingsRow(title: "我的水平", subtitle: "决定「重点表达」挑哪些词：只挑对你有价值的，跳过你肯定会的") {
                    Picker("", selection: $settings.learnerLevel) {
                        ForEach(LearnerLevel.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 190)
                }
            }
            SettingsCard(header: "生词本") {
                SettingsRow(title: "查单词时自动加入生词本", subtitle: "划选外语单词 / 短语时自动收录，附带原句") {
                    Toggle("", isOn: $settings.autoAddWords).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                SettingsRow(title: "重点表达自动加入生词本", subtitle: "展开胶囊提取出的词组会自动收录") {
                    Toggle("", isOn: $settings.autoAddKeyItems).labelsHidden().toggleStyle(.switch)
                }
                Divider()
                SettingsRow(title: "生词本") {
                    HStack {
                        Button("打开生词本") { WindowManager.shared.showVocabulary() }
                        Button("导出 CSV…") { exportCSV() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @MainActor
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "SwipeSay-生词本.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? VocabularyStore.shared.exportCSV().write(to: url, atomically: true, encoding: .utf8)
    }
}
