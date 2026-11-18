import SwiftUI
import AppKit

/// A transparent strip that moves its window when dragged.
///
/// `isMovableByWindowBackground` doesn't help a SwiftUI popup: `NSHostingView` doesn't let mouse-downs
/// move the window, and most of the content is selectable text or a scroll view anyway. Put this behind
/// chrome such as the header and footer; buttons and menus drawn on top still get their clicks.
struct WindowDragArea: NSViewRepresentable {
    /// Called once per gesture, after the window has actually moved.
    var onMoved: () -> Void = {}

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.onMoved = onMoved
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.onMoved = onMoved
    }

    final class DragView: NSView {
        var onMoved: () -> Void = {}
        private var startMouse: NSPoint?
        private var startOrigin: NSPoint?
        private var moved = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
            startOrigin = window?.frame.origin
            moved = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let startMouse, let startOrigin else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x, dy = now.y - startMouse.y
            // Ignore jitter so a plain click doesn't count as a move.
            guard moved || abs(dx) > 2 || abs(dy) > 2 else { return }
            if !moved {
                moved = true
                onMoved()
            }
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            startMouse = nil
            startOrigin = nil
        }
    }
}
