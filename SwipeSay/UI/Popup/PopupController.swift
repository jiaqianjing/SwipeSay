import AppKit
import SwiftUI

final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        PopupController.shared.handleEscape()
    }
}

/// Owns the floating translation panel.
@MainActor
final class PopupController {
    static let shared = PopupController()

    private var panel: PopupPanel?
    private var model: PopupViewModel?
    private var monitors: [Any] = []
    private let maxHeight: CGFloat = 640

    var isVisible: Bool { panel?.isVisible ?? false }

    #if DEBUG
    var debugModel: PopupViewModel? { model }
    #endif

    func show(_ captured: CapturedText, inputMode: Bool = false) {
        model?.cancelAll()
        let model = PopupViewModel(captured: captured, inputMode: inputMode)
        self.model = model

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let root = PopupRootView(model: model, maxHeight: maxHeight) { [weak self] height in
            self?.resize(height: height)
        }
        .environmentObject(VocabularyStore.shared)
        panel.contentView = NSHostingView(rootView: root)

        let initialHeight: CGFloat = inputMode ? 200 : 150
        panel.setFrame(frame(for: captured.anchor ?? NSEvent.mouseLocation, height: initialHeight), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        installMonitors()
        if !inputMode { model.start() }
    }

    func close() {
        model?.cancelAll()
        model = nil
        removeMonitors()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.contentView = nil
        })
    }

    // MARK: Layout

    private func makePanel() -> PopupPanel {
        let panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: Theme.popupWidth, height: 160),
                               styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                               backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func frame(for anchor: NSPoint, height: CGFloat) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let width = Theme.popupWidth
        var x = anchor.x - 16
        var top = anchor.y - 8
        // Not enough room below the selection → open above it.
        if top - height < visible.minY { top = min(anchor.y + height + 28, visible.maxY) }
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        top = min(max(top, visible.minY + height + 8), visible.maxY - 8)
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    private func resize(height: CGFloat) {
        guard let panel else { return }
        let h = min(max(height, 60), maxHeight)
        var frame = panel.frame
        guard abs(frame.height - h) > 0.5 else { return }
        let top = frame.maxY
        frame.size.height = h
        frame.origin.y = top - h
        if let visible = panel.screen?.visibleFrame, frame.minY < visible.minY + 8 {
            frame.origin.y = visible.minY + 8
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: Dismissal

    /// Esc first clears a typed follow-up question; a second Esc closes the popup.
    func handleEscape() {
        if let model, !model.followUpDraft.isEmpty {
            model.followUpDraft = ""
            return
        }
        close()
    }

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model, !model.keepsOpen else { return }
                if let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) { return }
                self.close()
            }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let editor = self.panel?.firstResponder as? NSTextView
            // Keys typed during IME composition (e.g. pinyin) belong to the input method.
            if editor?.hasMarkedText() == true { return event }
            switch event.keyCode {
            case 53: // Esc
                self.handleEscape()
                return nil
            case 36, 76: // Return / keypad Enter
                // ⇧↩ inserts a newline instead of submitting, like ⌥↩ does.
                guard event.modifierFlags.contains(.shift), let editor else { return event }
                editor.insertNewlineIgnoringFieldEditor(nil)
                return nil
            default:
                return event
            }
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}
