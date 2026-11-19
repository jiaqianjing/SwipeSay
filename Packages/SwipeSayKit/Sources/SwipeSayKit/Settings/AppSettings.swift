import Foundation
import Combine
import NaturalLanguage
#if os(macOS)
import ServiceManagement
import AppKit
#endif

public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case russian = "ru"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .russian: return "Русский"
        }
    }

    /// Name used inside prompts.
    public var promptName: String {
        switch self {
        case .simplifiedChinese: return "Simplified Chinese (简体中文)"
        case .traditionalChinese: return "Traditional Chinese (繁體中文)"
        case .english: return "English"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .russian: return "Russian"
        }
    }

    public var nlLanguages: [NLLanguage] {
        switch self {
        case .simplifiedChinese, .traditionalChinese: return [.simplifiedChinese, .traditionalChinese]
        case .english: return [.english]
        case .japanese: return [.japanese]
        case .korean: return [.korean]
        case .french: return [.french]
        case .german: return [.german]
        case .spanish: return [.spanish]
        case .russian: return [.russian]
        }
    }
}

public enum LearnerLevel: String, CaseIterable, Identifiable, Codable {
    case beginner, intermediate, upperIntermediate, advanced

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .beginner: return "入门（初高中）"
        case .intermediate: return "中级（四级）"
        case .upperIntermediate: return "中高级（六级 / 考研）"
        case .advanced: return "高级（雅思 / 托福 / 专业）"
        }
    }

    public var promptDescription: String {
        switch self {
        case .beginner: return "a beginner (roughly CEFR A2, high-school level)"
        case .intermediate: return "an intermediate learner (roughly CEFR B1, CET-4 level)"
        case .upperIntermediate: return "an upper-intermediate learner (roughly CEFR B2, CET-6 level)"
        case .advanced: return "an advanced learner (roughly CEFR C1, IELTS 7+)"
        }
    }
}

/// How long cached translation results are kept, counted from when the result was produced.
public enum CacheRetention: String, CaseIterable, Identifiable {
    case days30, days90, forever

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .days30: return "30 天"
        case .days90: return "90 天"
        case .forever: return "永久"
        }
    }

    public var days: Int? {
        switch self {
        case .days30: return 30
        case .days90: return 90
        case .forever: return nil
        }
    }
}

/// User-chosen cap on the translation cache's size. Stored as megabytes.
public enum CacheSizeLimit: Int, CaseIterable, Identifiable {
    case mb256 = 256, mb512 = 512, gb1 = 1024, gb2 = 2048, gb5 = 5120

    public var id: Int { rawValue }

    public var displayName: String { rawValue < 1024 ? "\(rawValue) MB" : "\(rawValue / 1024) GB" }

    public var bytes: Int { rawValue * 1024 * 1024 }

    /// Maps any stored value onto an option: values in between round down, anything above the hard
    /// maximum becomes 5 GB, anything below the smallest option becomes 256 MB.
    public init(storedMegabytes mb: Int) {
        self = Self.allCases.last { $0.rawValue <= mb } ?? .mb256
    }
}

public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults = SharedStorage.defaults

    private enum Key {
        public static let target = "targetLanguage"
        public static let secondary = "secondaryLanguage"
        public static let quickIcon = "showQuickIcon"
        public static let autoAddWords = "autoAddWords"
        public static let autoAddKeyItems = "autoAddKeyItems"
        public static let useContext = "useContext"
        public static let dockIcon = "showDockIcon"
        public static let level = "learnerLevel"
        public static let selectionShortcut = "shortcut.selection"
        public static let screenshotShortcut = "shortcut.screenshot"
        public static let inputShortcut = "shortcut.input"
        public static let didOnboard = "didOnboard"
        public static let speechVoices = "speechVoices"
        public static let cacheEnabled = "translationCache.enabled"
        public static let cacheRetention = "translationCache.retention"
        public static let cacheSizeLimit = "translationCache.sizeLimitMB"
        public static let aiConsent = "aiConsent.providers"
    }

    @Published public var targetLanguage: AppLanguage { didSet { defaults.set(targetLanguage.rawValue, forKey: Key.target) } }
    /// Used when the source text is already in the target language.
    @Published public var secondaryLanguage: AppLanguage { didSet { defaults.set(secondaryLanguage.rawValue, forKey: Key.secondary) } }
    @Published public var showQuickIcon: Bool { didSet { defaults.set(showQuickIcon, forKey: Key.quickIcon) } }
    @Published public var autoAddWords: Bool { didSet { defaults.set(autoAddWords, forKey: Key.autoAddWords) } }
    @Published public var autoAddKeyItems: Bool { didSet { defaults.set(autoAddKeyItems, forKey: Key.autoAddKeyItems) } }
    @Published public var useContext: Bool { didSet { defaults.set(useContext, forKey: Key.useContext) } }
    @Published public var learnerLevel: LearnerLevel { didSet { defaults.set(learnerLevel.rawValue, forKey: Key.level) } }
    @Published public var showDockIcon: Bool {
        didSet {
            defaults.set(showDockIcon, forKey: Key.dockIcon)
            #if os(macOS)
            applyActivationPolicy()
            #endif
        }
    }
    #if os(macOS)
    @Published public var selectionShortcut: Shortcut { didSet { save(selectionShortcut, Key.selectionShortcut) } }
    @Published public var screenshotShortcut: Shortcut { didSet { save(screenshotShortcut, Key.screenshotShortcut) } }
    @Published public var inputShortcut: Shortcut { didSet { save(inputShortcut, Key.inputShortcut) } }
    #endif
    @Published public var didOnboard: Bool { didSet { defaults.set(didOnboard, forKey: Key.didOnboard) } }
    /// Chosen speech voice identifier per `AppLanguage.rawValue`; a missing entry means "best available".
    @Published public var speechVoices: [String: String] { didSet { defaults.set(speechVoices, forKey: Key.speechVoices) } }
    @Published public var cacheEnabled: Bool { didSet { defaults.set(cacheEnabled, forKey: Key.cacheEnabled) } }
    @Published public var cacheRetention: CacheRetention {
        didSet { defaults.set(cacheRetention.rawValue, forKey: Key.cacheRetention) }
    }
    @Published public var cacheSizeLimit: CacheSizeLimit {
        didSet { defaults.set(cacheSizeLimit.rawValue, forKey: Key.cacheSizeLimit) }
    }

    #if os(iOS)
    /// Provider IDs the user agreed to send text to (App Review guideline 5.1.2(i): disclose and ask before
    /// sharing data with a third-party AI service).
    @Published public var aiConsentProviders: Set<String> {
        didSet { defaults.set(Array(aiConsentProviders), forKey: Key.aiConsent) }
    }
    #endif

    #if os(macOS)
    @Published public var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("SwipeSay: launch at login failed: \(error)")
            }
        }
    }
    #endif

    private init() {
        defaults.register(defaults: [
            Key.quickIcon: true,
            Key.autoAddWords: true,
            Key.autoAddKeyItems: true,
            Key.useContext: true,
            Key.dockIcon: false,
            Key.cacheEnabled: true,
            Key.cacheSizeLimit: CacheSizeLimit.gb1.rawValue,
        ])
        targetLanguage = AppLanguage(rawValue: defaults.string(forKey: Key.target) ?? "") ?? .simplifiedChinese
        secondaryLanguage = AppLanguage(rawValue: defaults.string(forKey: Key.secondary) ?? "") ?? .english
        showQuickIcon = defaults.bool(forKey: Key.quickIcon)
        autoAddWords = defaults.bool(forKey: Key.autoAddWords)
        autoAddKeyItems = defaults.bool(forKey: Key.autoAddKeyItems)
        useContext = defaults.bool(forKey: Key.useContext)
        showDockIcon = defaults.bool(forKey: Key.dockIcon)
        learnerLevel = LearnerLevel(rawValue: defaults.string(forKey: Key.level) ?? "") ?? .upperIntermediate
        didOnboard = defaults.bool(forKey: Key.didOnboard)
        speechVoices = defaults.dictionary(forKey: Key.speechVoices) as? [String: String] ?? [:]
        cacheEnabled = defaults.bool(forKey: Key.cacheEnabled)
        cacheRetention = CacheRetention(rawValue: defaults.string(forKey: Key.cacheRetention) ?? "") ?? .days90
        cacheSizeLimit = CacheSizeLimit(storedMegabytes: defaults.integer(forKey: Key.cacheSizeLimit))
        #if os(macOS)
        selectionShortcut = Self.load(Key.selectionShortcut) ?? .defaultSelection
        screenshotShortcut = Self.load(Key.screenshotShortcut) ?? .defaultScreenshot
        inputShortcut = Self.load(Key.inputShortcut) ?? .defaultInput
        #else
        aiConsentProviders = Set(defaults.stringArray(forKey: Key.aiConsent) ?? [])
        #endif
    }

    #if os(iOS)
    /// Consent is tied to the provider and the host it sends to, so pointing a provider at another server asks again.
    private func consentKey(_ config: ProviderConfig) -> String {
        "\(config.id.uuidString)|\(config.endpointHost)"
    }
    public func hasAIConsent(for config: ProviderConfig) -> Bool { aiConsentProviders.contains(consentKey(config)) }
    public func grantAIConsent(for config: ProviderConfig) { aiConsentProviders.insert(consentKey(config)) }
    public func revokeAIConsent(for config: ProviderConfig) {
        aiConsentProviders = aiConsentProviders.filter { !$0.hasPrefix(config.id.uuidString) }
    }

    /// Re-reads what the app may have changed since this process started. The Safari extension's process can
    /// outlive many visits to the app's settings.
    public func reloadFromStorage() {
        func update<T: Equatable>(_ path: ReferenceWritableKeyPath<AppSettings, T>, _ value: T) {
            if self[keyPath: path] != value { self[keyPath: path] = value }
        }
        update(\.targetLanguage, AppLanguage(rawValue: defaults.string(forKey: Key.target) ?? "") ?? .simplifiedChinese)
        update(\.secondaryLanguage, AppLanguage(rawValue: defaults.string(forKey: Key.secondary) ?? "") ?? .english)
        update(\.autoAddWords, defaults.bool(forKey: Key.autoAddWords))
        update(\.autoAddKeyItems, defaults.bool(forKey: Key.autoAddKeyItems))
        update(\.useContext, defaults.bool(forKey: Key.useContext))
        update(\.learnerLevel, LearnerLevel(rawValue: defaults.string(forKey: Key.level) ?? "") ?? .upperIntermediate)
        update(\.cacheEnabled, defaults.bool(forKey: Key.cacheEnabled))
        update(\.aiConsentProviders, Set(defaults.stringArray(forKey: Key.aiConsent) ?? []))
    }
    #endif

    #if os(macOS)
    public func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    private func save(_ shortcut: Shortcut, _ key: String) {
        if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: key) }
    }

    private static func load(_ key: String) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }
#endif
}
