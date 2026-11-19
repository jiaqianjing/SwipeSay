import AppKit
import SwipeSayKit
import Vision

/// Interactive region capture (system crosshair UI) + on-device OCR with Vision.
enum ScreenshotOCR {
    static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestScreenAccess() -> Bool { CGRequestScreenCaptureAccess() }

    /// Lets the user drag a region; returns nil if cancelled.
    static func captureRegion() async -> CGImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swipesay-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-o", url.path]
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } catch {
            return nil
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Recognises text and rebuilds paragraphs from the line layout.
    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES", "ru-RU"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return assemble(request.results ?? [])
        }.value
    }

    private struct Line { var text: String; var box: CGRect }

    private static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        let lines = observations.compactMap { obs -> Line? in
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            return Line(text: text, box: obs.boundingBox)
        }
        // Vision boxes are normalised with origin bottom-left: sort top→bottom, then left→right.
        .sorted { a, b in
            if abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) * 0.5 { return a.box.minX < b.box.minX }
            return a.box.midY > b.box.midY
        }
        guard !lines.isEmpty else { return "" }
        let avgHeight = lines.map(\.box.height).reduce(0, +) / CGFloat(lines.count)

        var paragraphs: [String] = []
        var current = lines[0].text
        for i in 1..<lines.count {
            let prev = lines[i - 1], line = lines[i]
            let gap = prev.box.minY - line.box.maxY
            let sameRow = abs(prev.box.midY - line.box.midY) < avgHeight * 0.5
            if sameRow {
                current += " " + line.text
            } else if gap > avgHeight * 0.9 || current.hasSuffix(":") {
                paragraphs.append(current)
                current = line.text
            } else {
                current = join(current, line.text)
            }
        }
        paragraphs.append(current)
        return paragraphs.joined(separator: "\n\n")
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.hasSuffix("-"), let last = a.dropLast().last, last.isLetter { return String(a.dropLast()) + b }
        let cjk: (Character?) -> Bool = { c in
            guard let s = c?.unicodeScalars.first else { return false }
            return (0x3000...0x9FFF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value) || (0xFF00...0xFFEF).contains(s.value)
        }
        if cjk(a.last) || cjk(b.first) { return a + b }
        return a + " " + b
    }
}
