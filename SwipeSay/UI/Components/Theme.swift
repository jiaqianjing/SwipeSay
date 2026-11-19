import SwiftUI
import SwipeSayKit
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Theme {
    /// Coral highlighter from the app icon.
    static let accent = Color(red: 0.95, green: 0.39, blue: 0.36)
    /// Warm yellow from the icon background.
    static let highlight = Color(red: 1.0, green: 0.78, blue: 0.24)
    static let corner: CGFloat = 16
    static let popupWidth: CGFloat = 420

    /// Font size for the shared result views: the Mac popup is dense, the iOS screens need larger text.
    static func fs(_ size: CGFloat) -> CGFloat {
        #if os(iOS)
        return (size * 1.22).rounded()
        #else
        return size
        #endif
    }
}

#if os(macOS)
/// Native translucent background.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    /// Debug-only `-SwipeSayFlatBackground YES` draws a solid fill instead of the blur, so screenshots
    /// (including in-app snapshots, which can't render the window-server blur) look the same anywhere.
    private var flat: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "SwipeSayFlatBackground")
        #else
        return false
        #endif
    }

    func makeNSView(context: Context) -> NSView {
        if flat { return FlatBackgroundView() }
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let v = v as? NSVisualEffectView else { return }
        v.material = material
        v.blendingMode = blending
    }
}

/// Solid window-background fill that follows light/dark appearance.
final class FlatBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
#endif

/// Small rounded tag.
struct TagView: View {
    var text: String
    var color: Color = Theme.accent

    var body: some View {
        Text(text)
            .font(.system(size: Theme.fs(10), weight: .semibold))
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
                .font(.system(size: Theme.fs(12), weight: .medium))
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
        let lang = TranslationService.detectLanguage(text) ?? .english
        speak(text, voice: voice(for: lang))
    }

    /// Plays a short sample in `lang` with the currently configured voice (used by Settings).
    static func preview(_ lang: AppLanguage) {
        speak(lang.speechSample, voice: voice(for: lang))
    }

    /// The user's chosen voice for `lang` if it is still installed, otherwise the best installed one.
    static func voice(for lang: AppLanguage) -> AVSpeechSynthesisVoice? {
        if let id = AppSettings.shared.speechVoices[lang.rawValue],
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        return bestVoice(for: lang)
    }

    /// Highest-quality installed voice (premium > enhanced > default); ties go to the preferred
    /// region, then to the system's own default voice so nothing changes when only basic voices exist.
    static func bestVoice(for lang: AppLanguage) -> AVSpeechSynthesisVoice? {
        let fallback = AVSpeechSynthesisVoice(language: lang.speechCode)
        let candidates = installedVoices(for: lang).filter { lang.allowsOtherSpeechRegions || $0.language == lang.speechCode }
        func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int, Int) {
            (v.quality.rawValue, v.language == lang.speechCode ? 1 : 0, v.identifier == fallback?.identifier ? 1 : 0)
        }
        return candidates.max { rank($0) < rank($1) } ?? fallback
    }

    /// Installed voices that can read `lang`, preferred region first, then by quality and name.
    /// Novelty and Personal Voice entries are left out.
    static func installedVoices(for lang: AppLanguage) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { lang.speechMatches($0.language) && $0.voiceTraits.isDisjoint(with: [.isNoveltyVoice, .isPersonalVoice]) }
            .sorted { a, b in
                let ra = a.language == lang.speechCode, rb = b.language == lang.speechCode
                if ra != rb { return ra }
                if a.language != b.language { return a.language < b.language }
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    /// Picker label, e.g. "Ava（高级）· 美国".
    static func displayName(_ voice: AVSpeechSynthesisVoice) -> String {
        var name = voice.name
        for suffix in [" (Enhanced)", " (Premium)"] { name = name.replacingOccurrences(of: suffix, with: "") }
        switch voice.quality {
        case .premium: name += "（高级）"
        case .enhanced: name += "（增强）"
        default: break
        }
        if let region = Locale(identifier: voice.language).region?.identifier,
           let regionName = Locale(identifier: "zh-Hans").localizedString(forRegionCode: region) {
            name += " · \(regionName)"
        }
        return name
    }

    private static func speak(_ text: String, voice: AVSpeechSynthesisVoice?) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synth.speak(utterance)
    }
}

extension AppLanguage {
    /// BCP-47 code of the preferred voice region for this language.
    var speechCode: String {
        switch self {
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .spanish: return "es-ES"
        case .russian: return "ru-RU"
        }
    }

    /// Whether a voice with the given BCP-47 language can read this language.
    func speechMatches(_ voiceLanguage: String) -> Bool {
        switch self {
        case .simplifiedChinese: return voiceLanguage == "zh-CN"
        case .traditionalChinese: return voiceLanguage == "zh-TW" || voiceLanguage == "zh-HK"
        default: return voiceLanguage.split(separator: "-").first == speechCode.split(separator: "-").first
        }
    }

    /// Automatic choice may use another region's voice (e.g. a premium en-GB voice for English).
    /// Not for Chinese, where zh-HK voices speak Cantonese.
    var allowsOtherSpeechRegions: Bool { !TranslationService.isChinese(self) }

    /// Short sentence for the Settings "试听" button.
    var speechSample: String {
        switch self {
        case .simplifiedChinese: return "划词即译，边读边学。"
        case .traditionalChinese: return "劃詞即譯，邊讀邊學。"
        case .english: return "Every word you select is a chance to learn something new."
        case .japanese: return "選んだ言葉をすぐに翻訳して、読みながら学べます。"
        case .korean: return "선택한 단어를 바로 번역하고, 읽으면서 배울 수 있어요."
        case .french: return "Chaque mot sélectionné est une occasion d'apprendre."
        case .german: return "Jedes markierte Wort ist eine Gelegenheit zum Lernen."
        case .spanish: return "Cada palabra seleccionada es una oportunidad para aprender."
        case .russian: return "Каждое выделенное слово — повод узнать что-то новое."
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
