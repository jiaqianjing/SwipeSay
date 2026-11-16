import AppKit
import ApplicationServices

/// Reads the current text selection in the frontmost app together with the surrounding text.
///
/// Strategy:
/// 1. Accessibility: selected text + full value + selected range → paragraph(s) around it (native text views).
/// 2. Accessibility text markers (WebKit / Chromium web content) → the enclosing paragraph.
/// 3. Fallback: simulate ⌘C and read the pasteboard (no context), then restore the pasteboard.
enum SelectionCapture {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Full capture used by the hotkey. Falls back to the clipboard when AX gives nothing.
    static func capture() async -> CapturedText? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        if frontApp?.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        if var result = captureViaAccessibility(app: frontApp) {
            if result.anchor == nil { result.anchor = NSEvent.mouseLocation }
            return result
        }
        guard let copied = await copyViaPasteboard(), !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return CapturedText(text: copied, context: nil, appName: frontApp?.localizedName,
                            bundleID: frontApp?.bundleIdentifier, windowTitle: windowTitle(of: frontApp),
                            origin: .selection, anchor: NSEvent.mouseLocation)
    }

    /// Accessibility-only capture (no pasteboard side effects) — used by the quick icon.
    static func captureViaAccessibility(app: NSRunningApplication?) -> CapturedText? {
        guard isTrusted, let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium / Electron only build their AX tree when asked.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let focused: AXUIElement = attribute(appElement, kAXFocusedUIElementAttribute) else { return nil }
        guard let selected: String = attribute(focused, kAXSelectedTextAttribute),
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var context: String?
        var anchor: NSPoint?

        if let range: CFRange = rangeAttribute(focused, kAXSelectedTextRangeAttribute) {
            if let full: String = attribute(focused, kAXValueAttribute), (full as NSString).length >= range.location + range.length {
                context = ContextExtractor.surrounding(in: full, range: NSRange(location: range.location, length: range.length))
            }
            anchor = bounds(of: focused, range: range)
        }
        if context == nil {
            context = webParagraph(focused)
        }
        return CapturedText(text: selected, context: context, appName: app.localizedName, bundleID: app.bundleIdentifier,
                            windowTitle: windowTitle(of: app), origin: .selection, anchor: anchor)
    }

    // MARK: - Text markers (WebKit / Chromium)

    private static func webParagraph(_ element: AXUIElement) -> String? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let markerRange else { return nil }
        guard let start = parameterized(element, "AXStartTextMarkerForTextMarkerRange", markerRange) else { return nil }
        var pieces: [String] = []
        if let para = parameterized(element, "AXParagraphTextMarkerRangeForTextMarker", start),
           let text = parameterized(element, "AXStringForTextMarkerRange", para) as? String {
            pieces.append(text)
            // Try to add the previous paragraph for extra context.
            if let paraStart = parameterized(element, "AXStartTextMarkerForTextMarkerRange", para),
               let prevMarker = parameterized(element, "AXPreviousTextMarkerForTextMarker", paraStart),
               let prevPara = parameterized(element, "AXParagraphTextMarkerRangeForTextMarker", prevMarker),
               let prevText = parameterized(element, "AXStringForTextMarkerRange", prevPara) as? String,
               prevText != text {
                pieces.insert(prevText, at: 0)
            }
        }
        let joined = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : String(joined.prefix(2000))
    }

    // MARK: - Pasteboard fallback

    @MainActor
    static func copyViaPasteboard() async -> String? {
        guard isTrusted else { return nil }
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let d = item.data(forType: type) { dict[type] = d } }
            return dict
        } ?? []
        let before = pb.changeCount

        // Give the user a moment to release the hotkey modifiers.
        try? await Task.sleep(nanoseconds: 60_000_000)
        postCommandC()

        var result: String?
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if pb.changeCount != before {
                result = pb.string(forType: .string)
                break
            }
        }
        if pb.changeCount != before {
            pb.clearContents()
            let items = saved.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        return result
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyC: CGKeyCode = 8
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - AX helpers

    static func windowTitle(of app: NSRunningApplication?) -> String? {
        guard isTrusted, let app else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute) else { return nil }
        let title: String? = attribute(window, kAXTitleAttribute)
        return title
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }

    private static func rangeAttribute(_ element: AXUIElement, _ name: String) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ param: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, param, &value) == .success else { return nil }
        return value
    }

    /// Screen rect of the selection, converted to an AppKit anchor point just below it.
    private static func bounds(of element: AXUIElement, range: CFRange) -> NSPoint? {
        var r = range
        guard let rangeValue = AXValueCreate(.cfRange, &r),
              let value = parameterized(element, kAXBoundsForRangeParameterizedAttribute, rangeValue),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        // AX uses top-left origin on the primary screen; AppKit uses bottom-left.
        guard let primary = NSScreen.screens.first else { return nil }
        let bottomY = primary.frame.maxY - rect.maxY
        return NSPoint(x: rect.minX, y: bottomY)
    }
}

/// Finds a useful window of text around a selection.
enum ContextExtractor {
    static func surrounding(in full: String, range: NSRange, budget: Int = 1400) -> String? {
        let ns = full as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= ns.length, ns.length > range.length else { return nil }
        var para = ns.paragraphRange(for: range)
        // Grow by neighbouring paragraphs while within budget.
        while para.length < budget {
            var grown = para
            if grown.location > 0 { grown = NSUnionRange(grown, ns.paragraphRange(for: NSRange(location: grown.location - 1, length: 0))) }
            if NSMaxRange(grown) < ns.length { grown = NSUnionRange(grown, ns.paragraphRange(for: NSRange(location: NSMaxRange(grown), length: 0))) }
            if grown == para || grown.length > budget * 2 { break }
            para = grown
        }
        // Clip around the selection if still too long.
        if para.length > budget {
            let center = range.location + range.length / 2
            let start = max(para.location, center - budget / 2)
            let end = min(NSMaxRange(para), start + budget)
            para = NSRange(location: start, length: end - start)
        }
        let text = ns.substring(with: para).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
