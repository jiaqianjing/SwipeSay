import Foundation
import Combine
import NaturalLanguage
import ServiceManagement
import AppKit

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case russian = "ru"

    var id: String { rawValue }

    var displayName: String {
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
    var promptName: String {
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

    var nlLanguages: [NLLanguage] {
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

enum LearnerLevel: String, CaseIterable, Identifiable, Codable {
    case beginner, intermediate, upperIntermediate, advanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .beginner: return "入门（初高中）"
        case .intermediate: return "中级（四级）"
        case .upperIntermediate: return "中高级（六级 / 考研）"
        case .advanced: return "高级（雅思 / 托福 / 专业）"
        }
    }

    var promptDescription: String {
        switch self {
        case .beginner: return "a beginner (roughly CEFR A2, high-school level)"
        case .intermediate: return "an intermediate learner (roughly CEFR B1, CET-4 level)"
        case .upperIntermediate: return "an upper-intermediate learner (roughly CEFR B2, CET-6 level)"
        case .advanced: return "an advanced learner (roughly CEFR C1, IELTS 7+)"
        }
    }
}

/// How long cached translation results are kept, counted from when the result was produced.
enum CacheRetention: String, CaseIterable, Identifiable {
    case days30, days90, forever

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .days30: return "30 天"
        case .days90: return "90 天"
        case .forever: return "永久"
        }
    }

    var days: Int? {
        switch self {
        case .days30: return 30
        case .days90: return 90
        case .forever: return nil
        }
    }
}

/// User-chosen cap on the translation cache's size. Stored as megabytes.
enum CacheSizeLimit: Int, CaseIterable, Identifiable {
    case mb256 = 256, mb512 = 512, gb1 = 1024, gb2 = 2048, gb5 = 5120

    var id: Int { rawValue }

    var displayName: String { rawValue < 1024 ? "\(rawValue) MB" : "\(rawValue / 1024) GB" }

    var bytes: Int { rawValue * 1024 * 1024 }

    /// Maps any stored value onto an option: values in between round down, anything above the hard
    /// maximum becomes 5 GB, anything below the smallest option becomes 256 MB.
    init(storedMegabytes mb: Int) {
        self = Self.allCases.last { $0.rawValue <= mb } ?? .mb256
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let target = "targetLanguage"
        static let secondary = "secondaryLanguage"
        static let quickIcon = "showQuickIcon"
        static let autoAddWords = "autoAddWords"
        static let autoAddKeyItems = "autoAddKeyItems"
        static let useContext = "useContext"
        static let dockIcon = "showDockIcon"
        static let level = "learnerLevel"
        static let selectionShortcut = "shortcut.selection"
        static let screenshotShortcut = "shortcut.screenshot"
        static let inputShortcut = "shortcut.input"
        static let didOnboard = "didOnboard"
        static let speechVoices = "speechVoices"
        static let cacheEnabled = "translationCache.enabled"
        static let cacheRetention = "translationCache.retention"
        static let cacheSizeLimit = "translationCache.sizeLimitMB"
    }

    @Published var targetLanguage: AppLanguage { didSet { defaults.set(targetLanguage.rawValue, forKey: Key.target) } }
    /// Used when the source text is already in the target language.
    @Published var secondaryLanguage: AppLanguage { didSet { defaults.set(secondaryLanguage.rawValue, forKey: Key.secondary) } }
    @Published var showQuickIcon: Bool { didSet { defaults.set(showQuickIcon, forKey: Key.quickIcon) } }
    @Published var autoAddWords: Bool { didSet { defaults.set(autoAddWords, forKey: Key.autoAddWords) } }
    @Published var autoAddKeyItems: Bool { didSet { defaults.set(autoAddKeyItems, forKey: Key.autoAddKeyItems) } }
    @Published var useContext: Bool { didSet { defaults.set(useContext, forKey: Key.useContext) } }
    @Published var learnerLevel: LearnerLevel { didSet { defaults.set(learnerLevel.rawValue, forKey: Key.level) } }
    @Published var showDockIcon: Bool {
        didSet {
            defaults.set(showDockIcon, forKey: Key.dockIcon)
            applyActivationPolicy()
        }
    }
    @Published var selectionShortcut: Shortcut { didSet { save(selectionShortcut, Key.selectionShortcut) } }
    @Published var screenshotShortcut: Shortcut { didSet { save(screenshotShortcut, Key.screenshotShortcut) } }
    @Published var inputShortcut: Shortcut { didSet { save(inputShortcut, Key.inputShortcut) } }
    @Published var didOnboard: Bool { didSet { defaults.set(didOnboard, forKey: Key.didOnboard) } }
    /// Chosen speech voice identifier per `AppLanguage.rawValue`; a missing entry means "best available".
    @Published var speechVoices: [String: String] { didSet { defaults.set(speechVoices, forKey: Key.speechVoices) } }
    @Published var cacheEnabled: Bool { didSet { defaults.set(cacheEnabled, forKey: Key.cacheEnabled) } }
    @Published var cacheRetention: CacheRetention {
        didSet { defaults.set(cacheRetention.rawValue, forKey: Key.cacheRetention) }
    }
    @Published var cacheSizeLimit: CacheSizeLimit {
        didSet { defaults.set(cacheSizeLimit.rawValue, forKey: Key.cacheSizeLimit) }
    }

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("SwipeSay: launch at login failed: \(error)")
            }
        }
    }

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
        selectionShortcut = Self.load(Key.selectionShortcut) ?? .defaultSelection
        screenshotShortcut = Self.load(Key.screenshotShortcut) ?? .defaultScreenshot
        inputShortcut = Self.load(Key.inputShortcut) ?? .defaultInput
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    private func save(_ shortcut: Shortcut, _ key: String) {
        if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: key) }
    }

    private static func load(_ key: String) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }
}
