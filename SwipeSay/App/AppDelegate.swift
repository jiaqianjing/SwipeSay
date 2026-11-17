import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private let settings = AppSettings.shared
    private var cancellables: Set<AnyCancellable> = []
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        settings.applyActivationPolicy()
        _ = VocabularyStore.shared
        _ = TranslationCache.shared // schedules expiry pruning and eviction shortly after launch
        Updater.shared.start()

        registerHotkeys()
        Publishers.Merge3(settings.$selectionShortcut, settings.$screenshotShortcut, settings.$inputShortcut)
            .dropFirst(3)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.registerHotkeys() }
            .store(in: &cancellables)

        SelectionMonitor.shared.onTrigger = { captured in
            PopupController.shared.show(captured)
        }
        SelectionMonitor.shared.start()

        #if DEBUG
        // `-SwipeSayAppearance light|dark` forces the app's appearance, for screenshots.
        switch UserDefaults.standard.string(forKey: "SwipeSayAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        // Sample words go only into the in-memory mock store, never the real vocabulary.
        if MockClient.isEnabled, UserDefaults.standard.bool(forKey: "SwipeSayDemoVocabulary") {
            seedDemoVocabulary()
        }
        if let prefix = UserDefaults.standard.string(forKey: "SwipeSaySnapshot") {
            let delay = UserDefaults.standard.object(forKey: "SwipeSaySnapshotDelay") as? Double ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.snapshotWindows(to: prefix)
                NSApp.terminate(nil)
            }
        }
        switch UserDefaults.standard.string(forKey: "SwipeSayOpen") {
        case "vocabulary": WindowManager.shared.showVocabulary(); return
        case let tab?: if let t = SettingsTab(rawValue: tab) { WindowManager.shared.showSettings(tab: t); return }
        case nil: break
        }
        if let demo = UserDefaults.standard.string(forKey: "SwipeSayDemo") {
            runDemo(demo)
            return
        }
        #endif

        if !settings.didOnboard || !SelectionCapture.isTrusted || ProviderStore.shared.active?.isReady != true {
            settings.didOnboard = true
            WindowManager.shared.showSettings(tab: SelectionCapture.isTrusted ? .providers : .general)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.showSettings() }
        return true
    }

    private func registerHotkeys() {
        let hk = HotkeyManager.shared
        hk.register(.selection, shortcut: settings.selectionShortcut) { [weak self] in self?.translateSelection() }
        hk.register(.screenshot, shortcut: settings.screenshotShortcut) { [weak self] in self?.translateScreenshot() }
        hk.register(.input, shortcut: settings.inputShortcut) { [weak self] in self?.showInput() }
    }

    #if DEBUG
    /// `-SwipeSayDemo "text"` opens a popup for that text; `-SwipeSayDemoExpand YES` also opens the capsule and analysis.
    private func runDemo(_ text: String) {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let captured = CapturedText(
            text: text,
            context: "The storm had been raging for hours. \(text) She turned back toward the door, but it was already locked.",
            appName: "Safari", bundleID: "com.apple.Safari", windowTitle: "The House on the Hill",
            origin: .selection, anchor: NSPoint(x: screen.midX - 200, y: screen.maxY - 120))
        PopupController.shared.show(captured)
        guard UserDefaults.standard.bool(forKey: "SwipeSayDemoExpand") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            PopupController.shared.debugModel?.toggleCapsule()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
            PopupController.shared.debugModel?.loadAnalysis()
        }
    }

    /// `-SwipeSaySnapshot <path-prefix>` writes every visible window to `<prefix>-<n>.png` after
    /// `-SwipeSaySnapshotDelay` seconds (default 6), then quits. The app draws its own windows, so this needs no
    /// Screen Recording permission. Pair it with `-SwipeSayFlatBackground YES`, because the blur can't be drawn this way.
    private func snapshotWindows(to prefix: String) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 && $0.frame.height > 100 }
        for (i, window) in windows.enumerated() {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: "\(prefix)-\(i).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("snapshot \(url.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
    }

    /// `-SwipeSayDemoVocabulary YES` (mock mode only) fills the in-memory vocabulary with sample entries.
    private func seedDemoVocabulary() {
        let samples: [(String, String, String, String, String, String, String)] = [
            ("ubiquitous", "/juːˈbɪkwɪtəs/", "word", "无处不在的", "常与 become 连用；名词形式 ubiquity。",
             "Smartphones have become ubiquitous in modern life.", "智能手机在现代生活中已无处不在。"),
            ("no sooner … than", "", "pattern", "一……就……", "no sooner 置于句首时主谓倒装",
             "No sooner had she set foot in the house than she felt an inexplicable sense of dread.",
             "她刚一踏进那栋房子，就感到一种难以名状的恐惧。"),
            ("set foot in", "", "phrase", "踏入；进入", "",
             "No sooner had she set foot in the house than she felt an inexplicable sense of dread.",
             "她刚一踏进那栋房子，就感到一种难以名状的恐惧。"),
            ("inexplicable", "/ˌɪnɪkˈsplɪkəbl/", "word", "无法解释的", "比 strange 更正式",
             "She felt an inexplicable sense of dread.", "她感到一种难以名状的恐惧。"),
            ("hit the ground running", "", "idiom", "一上手就全力投入", "多用于新工作、新项目的开局",
             "The new team hit the ground running.", "新团队一上来就进入了状态。"),
            ("serendipity", "/ˌserənˈdɪpəti/", "word", "意外发现美好事物的运气", "",
             "Finding this café was pure serendipity.", "发现这家咖啡馆纯属意外之喜。"),
            ("take something with a grain of salt", "", "idiom", "对……半信半疑", "",
             "Take online reviews with a grain of salt.", "网上的评价要有所保留地看。"),
            ("meticulous", "/məˈtɪkjələs/", "word", "一丝不苟的", "褒义，强调对细节的极致关注",
             "She keeps meticulous notes.", "她的笔记做得一丝不苟。"),
        ]
        let apps = ["Safari", "Safari", "Safari", "Safari", "Slack", "Notes", "Chrome", "Mail"]
        for (i, s) in samples.enumerated() {
            VocabularyStore.shared.add(term: s.0, phonetic: s.1, kind: s.2, meaning: s.3, note: s.4,
                                       sentence: s.5, sentenceTranslation: s.6, sourceApp: apps[i])
        }
    }
    #endif

    // MARK: Actions

    func translateSelection() {
        guard !busy else { return }
        SelectionMonitor.shared.hideIcon()
        guard SelectionCapture.isTrusted else {
            SelectionCapture.requestAccessibility()
            WindowManager.shared.showSettings(tab: .general)
            return
        }
        busy = true
        Task {
            defer { busy = false }
            if let captured = await SelectionCapture.capture() {
                PopupController.shared.show(captured)
            } else {
                // Nothing selected: fall back to the input box.
                showInput()
            }
        }
    }

    func translateScreenshot() {
        guard !busy else { return }
        SelectionMonitor.shared.hideIcon()
        PopupController.shared.close()
        guard ScreenshotOCR.hasScreenAccess else {
            ScreenshotOCR.requestScreenAccess()
            WindowManager.shared.showSettings(tab: .general)
            return
        }
        busy = true
        Task {
            defer { busy = false }
            guard let image = await ScreenshotOCR.captureRegion() else { return }
            let anchor = NSEvent.mouseLocation
            do {
                let text = try await ScreenshotOCR.recognize(image)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    NSSound.beep()
                    return
                }
                PopupController.shared.show(CapturedText(text: text, context: nil, appName: nil, bundleID: nil,
                                                         windowTitle: nil, origin: .screenshot, anchor: anchor))
            } catch {
                NSSound.beep()
            }
        }
    }

    func showInput() {
        SelectionMonitor.shared.hideIcon()
        let anchor: NSPoint
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            anchor = NSPoint(x: f.midX - Theme.popupWidth / 2 + 16, y: f.maxY - f.height * 0.22)
        } else {
            anchor = NSEvent.mouseLocation
        }
        PopupController.shared.show(CapturedText(text: "", context: nil, appName: nil, bundleID: nil, windowTitle: nil,
                                                 origin: .manual, anchor: anchor), inputMode: true)
    }
}
