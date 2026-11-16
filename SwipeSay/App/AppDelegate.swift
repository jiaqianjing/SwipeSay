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
