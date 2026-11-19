import Foundation
import NaturalLanguage

enum TranslationMode { case word, sentence }

struct TranslationPlan {
    var mode: TranslationMode
    var direction: Prompts.Direction
    /// True when the selected text is in the user's own language (learning focuses on the translation instead).
    var sourceIsNative: Bool
}

enum TranslationService {
    static func detectLanguage(_ text: String) -> AppLanguage? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if !letters.isEmpty, letters.allSatisfy({ $0.isASCII }) { return .english }
        let recognizer = NLLanguageRecognizer()
        // Only choose among languages the app supports. Unconstrained, single Russian words are often taken for
        // Bulgarian or Ukrainian (e.g. "книга", "молоко"), which then maps to no language at all.
        recognizer.languageConstraints = AppLanguage.allCases.flatMap(\.nlLanguages)
        recognizer.processString(text)
        guard let lang = recognizer.dominantLanguage else { return nil }
        return AppLanguage.allCases.first { $0.nlLanguages.contains(lang) }
    }

    static func isChinese(_ lang: AppLanguage?) -> Bool {
        lang == .simplifiedChinese || lang == .traditionalChinese
    }

    static func sameLanguage(_ a: AppLanguage?, _ b: AppLanguage) -> Bool {
        guard let a else { return false }
        return a == b || (isChinese(a) && isChinese(b))
    }

    static func mode(for text: String) -> TranslationMode {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("\n") else { return .sentence }
        let hasCJK = t.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        if hasCJK { return t.count <= 4 ? .word : .sentence }
        if let last = t.last, ".!?。！？;；".contains(last) { return .sentence }
        let words = t.split { $0.isWhitespace }
        return (words.count <= 3 && t.count <= 40) ? .word : .sentence
    }

    static func plan(for text: String, settings: AppSettings = .shared) -> TranslationPlan {
        let source = detectLanguage(text)
        let native = settings.targetLanguage
        let sourceIsNative = sameLanguage(source, native)
        let target = sourceIsNative ? settings.secondaryLanguage : native
        return TranslationPlan(mode: mode(for: text),
                               direction: .init(source: source, target: target, native: native),
                               sourceIsNative: sourceIsNative)
    }

    static func activeClient() throws -> (LLMClient, ProviderConfig) {
        #if DEBUG
        if MockClient.isEnabled { return (MockClient(), MockClient.config) }
        #endif
        guard let config = ProviderStore.shared.active, config.isReady else { throw LLMError.notConfigured }
        #if os(iOS)
        guard AppSettings.shared.hasAIConsent(for: config) else { throw LLMError.consentRequired(config.name) }
        #endif
        return (LLMClientFactory.make(config), config)
    }
}
