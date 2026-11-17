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
    /// Backing scale the icon content was last rendered for.
    private var renderedScale: CGFloat = 0

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
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        if let screen {
            origin.x = min(max(origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - size.width)
            origin.y = min(max(origin.y, screen.visibleFrame.minY), screen.visibleFrame.maxY - size.height)
        }
        // Mouse coordinates are often fractional; snap to the target screen's pixel grid so the
        // circle and glyph edges don't straddle pixels (very visible on 1x displays).
        let scale = screen?.backingScaleFactor ?? panel.backingScaleFactor
        origin.x = (origin.x * scale).rounded() / scale
        origin.y = (origin.y * scale).rounded() / scale
        panel.setFrameOrigin(origin)
        // The panel is reused across screens; if this screen's scale differs from the one the
        // content was last rendered for, rebuild it so nothing is drawn at the old resolution.
        if scale != renderedScale { refreshContent(scale: scale) }
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
        panel.contentView = makeContentView()
        renderedScale = panel.backingScaleFactor
        // AppKit settles the window's real backing scale once it is on the new screen; re-render then too.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification,
                                               object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.iconPanel else { return }
                self.refreshContent(scale: panel.backingScaleFactor)
            }
        }
        return panel
    }

    private func makeContentView() -> NSView {
        NSHostingView(rootView: QuickIconView { [weak self] in
            guard let self, let captured = self.pending else { return }
            self.hideIcon()
            self.onTrigger?(captured)
        })
    }

    /// Replaces the hosting view so SwiftUI re-renders every layer at the new backing scale.
    private func refreshContent(scale: CGFloat) {
        guard let panel = iconPanel else { return }
        panel.contentView = makeContentView()
        renderedScale = scale
    }
}

private struct QuickIconView: View {
    var action: () -> Void
    @State private var hover = false

    /// Slightly deeper coral for hover; a color change keeps edges crisp where a scale transform would resample.
    private static let hoverFill = Color(red: 0.86, green: 0.30, blue: 0.28)

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill((hover ? Self.hoverFill : Theme.accent).gradient)
                // Bolder, slightly larger glyph: semibold 13pt strokes are about 1px wide on 1x screens and look soft.
                Image(systemName: "highlighter")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            .shadow(color: .black.opacity(hover ? 0.26 : 0.18), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .frame(width: 30, height: 30)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("SwipeSay 翻译")
    }
}
