import SwiftUI
import AppKit
import AVFoundation

enum Theme {
    /// Coral highlighter from the app icon.
    static let accent = Color(red: 0.95, green: 0.39, blue: 0.36)
    /// Warm yellow from the icon background.
    static let highlight = Color(red: 1.0, green: 0.78, blue: 0.24)
    static let corner: CGFloat = 16
    static let popupWidth: CGFloat = 420
}

/// Native translucent background.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

/// Small rounded tag.
struct TagView: View {
    var text: String
    var color: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Plain icon button used in headers.
struct IconButton: View {
    var systemName: String
    var help: String
    var active: Bool = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Theme.accent : (hover ? .primary : .secondary))
                .frame(width: 24, height: 24)
                .background(hover ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Animated placeholder lines while waiting for the model.
struct ShimmerLines: View {
    var lines: Int = 2
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(0..<lines, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 10)
                    .frame(maxWidth: i == lines - 1 ? 220 : .infinity, alignment: .leading)
            }
        }
        .overlay(
            GeometryReader { geo in
                LinearGradient(colors: [.clear, Color.white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: phase * geo.size.width)
            }
            .mask(
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0..<lines, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4).frame(height: 10)
                            .frame(maxWidth: i == lines - 1 ? 220 : .infinity, alignment: .leading)
                    }
                }
            )
        )
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.4 }
        }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Text-to-speech for pronunciation.
@MainActor
enum Speaker {
    private static let synth = AVSpeechSynthesizer()

    static func speak(_ text: String) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        let lang = TranslationService.detectLanguage(text)
        let code: String
        switch lang {
        case .simplifiedChinese: code = "zh-CN"
        case .traditionalChinese: code = "zh-TW"
        case .japanese: code = "ja-JP"
        case .korean: code = "ko-KR"
        case .french: code = "fr-FR"
        case .german: code = "de-DE"
        case .spanish: code = "es-ES"
        case .russian: code = "ru-RU"
        default: code = "en-US"
        }
        utterance.voice = AVSpeechSynthesisVoice(language: code)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synth.speak(utterance)
    }
}

extension NSPasteboard {
    static func copy(_ text: String) {
        general.clearContents()
        general.setString(text, forType: .string)
    }
}
