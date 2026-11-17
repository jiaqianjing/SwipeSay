import AppKit
import SwiftUI

/// Watches for mouse text selections in other apps and offers a small floating SwipeSay button.
@MainActor
final class SelectionMonitor {
    static let shared = SelectionMonitor()

    var onTrigger: ((CapturedText) -> Void)?

    private var monitors: [Any] = []
    private var mouseDownPoint: NSPoint = .zero
    private var mouseDownTime: Date = .distantPast
    private var iconPanel: NSPanel?
    private var pending: CapturedText?
    private var hideWork: DispatchWorkItem?

    func start() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel, .keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hideIcon()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDownPoint = NSEvent.mouseLocation
            mouseDownTime = Date()
            if let panel = iconPanel, !panel.frame.contains(NSEvent.mouseLocation) { hideIcon() }
        case .leftMouseUp:
            guard AppSettings.shared.showQuickIcon, SelectionCapture.isTrusted else { return }
            let up = NSEvent.mouseLocation
            let dragged = hypot(up.x - mouseDownPoint.x, up.y - mouseDownPoint.y) > 6
            let multiClick = event.clickCount >= 2
            guard dragged || multiClick else { return }
            // Let the target app finish updating its selection.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.checkSelection(at: up) }
        case .scrollWheel, .keyDown:
            hideIcon()
        default:
            break
        }
    }

    private func checkSelection(at point: NSPoint) {
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier,
              let captured = SelectionCapture.captureViaAccessibility(app: app) else { return }
        let text = captured.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 1, text.count <= 4000 else { return }
        var c = captured
        c.anchor = point
        pending = c
        showIcon(at: point)
    }

    private func showIcon(at point: NSPoint) {
        hideWork?.cancel()
        let size = CGSize(width: 30, height: 30)
        let panel = iconPanel ?? makePanel(size: size)
        iconPanel = panel
        var origin = NSPoint(x: point.x + 8, y: point.y - size.height - 10)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            origin.x = min(max(origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
            origin.y = min(max(origin.y, screen.visibleFrame.minY), screen.visibleFrame.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in self?.hideIcon() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    func hideIcon() {
        hideWork?.cancel()
        iconPanel?.orderOut(nil)
    }

    private func makePanel(size: CGSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: QuickIconView { [weak self] in
            guard let self, let captured = self.pending else { return }
            self.hideIcon()
            self.onTrigger?(captured)
        })
        return panel
    }
}

private struct QuickIconView: View {
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.accent.gradient)
                Image(systemName: "highlighter")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            .scaleEffect(hover ? 1.08 : 1)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .frame(width: 30, height: 30)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("SwipeSay 翻译")
    }
}
