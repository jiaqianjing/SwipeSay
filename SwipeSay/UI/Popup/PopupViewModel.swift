import Foundation
import SwiftUI

@MainActor
final class PopupViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, streaming, done
        case failed(String)

        var isBusy: Bool { self == .loading || self == .streaming }
    }

    /// One follow-up question and its (streamed) answer. Lives only as long as the popup.
    struct FollowUpTurn: Identifiable, Equatable {
        let id = UUID()
        var question: String
        var answer = ""
        var phase: Phase = .loading
    }

    @Published var captured: CapturedText
    @Published var sourceText: String
    @Published var isInputMode: Bool
    @Published var plan: TranslationPlan
    @Published var targetOverride: AppLanguage?

    @Published var phase: Phase = .idle
    @Published var translation = ""
    @Published var word: WordResult?
    @Published var notConfigured = false
    /// iOS: the active provider needs the user's consent before any text is sent to it.
    @Published var needsConsent = false

    @Published var capsuleExpanded = false
    /// Whether the word card's declension / conjugation tables are shown.
    @Published var formsExpanded = false
    @Published var keyItemsPhase: Phase = .idle
    @Published var keyItems: KeyItemsResult?

    @Published var analysisPhase: Phase = .idle
    @Published var analysis: SentenceAnalysis?

    @Published var followUpDraft = ""
    @Published var followUps: [FollowUpTurn] = []

    @Published var pinned = false
    @Published var sourceExpanded = false
    @Published var providerLabel = ""
    /// Set when the main result (sentence or word card) came from the local cache: when it was produced.
    @Published var cachedAt: Date?

    /// After "重新翻译", key items and analysis for this result also skip the cache (and overwrite it).
    private var bypassCache = false
    private var translateTask: Task<Void, Never>?
    private var keyItemsTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var followUpTask: Task<Void, Never>?
    /// How many earlier exchanges are sent back to the model with each follow-up.
    private let followUpHistoryLimit = 6
    private let settings = AppSettings.shared

    init(captured: CapturedText, inputMode: Bool = false) {
        self.captured = captured
        self.sourceText = captured.text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isInputMode = inputMode
        self.plan = TranslationService.plan(for: captured.text)
        if let p = ProviderStore.shared.active { providerLabel = p.model.isEmpty ? p.name : p.model }
    }

    // MARK: Derived

    var usedContext: Bool { settings.useContext && captured.hasUsefulContext }

    /// The foreign-language side of the pair (what the learner should study).
    var learningSentence: String { plan.sourceIsNative ? translation : sourceText }
    var learningTranslation: String { plan.sourceIsNative ? sourceText : translation }

    var canShowCapsule: Bool {
        guard plan.mode == .sentence, phase == .done else { return false }
        let words = learningSentence.split { $0.isWhitespace }.count
        let cjk = learningSentence.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return words >= 3 || cjk >= 6
    }

    var currentTarget: AppLanguage { targetOverride ?? plan.direction.target }

    /// Follow-ups are offered once there is a finished result to talk about.
    var canFollowUp: Bool { phase == .done }
    var isFollowUpBusy: Bool { followUps.last?.phase.isBusy == true }
    var canSendFollowUp: Bool {
        canFollowUp && !isFollowUpBusy && !followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An outside click must not throw away a typed question or an ongoing conversation.
    var keepsOpen: Bool { pinned || !followUpDraft.isEmpty || !followUps.isEmpty }

    /// Moving the popup means the user wants to keep it around, so pin it: a click elsewhere
    /// (e.g. back in the app being read) no longer dismisses it.
    func didMoveWindow() { pinned = true }

    // MARK: Actions

    func start() {
        guard !sourceText.isEmpty else { return }
        translate()
    }

    func submitInput() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        captured.text = text
        captured.context = nil
        translate()
    }

    func setTarget(_ lang: AppLanguage) {
        targetOverride = lang
        translate()
    }

    /// Ignores the cache for this result and overwrites the cached entry with the fresh one.
    func retranslate() {
        translate(bypassCache: true)
    }

    func translate(bypassCache: Bool = false) {
        cancelAll()
        plan = TranslationService.plan(for: sourceText)
        if let override = targetOverride { plan.direction.target = override }
        translation = ""
        word = nil
        keyItems = nil
        keyItemsPhase = .idle
        analysis = nil
        analysisPhase = .idle
        capsuleExpanded = false
        formsExpanded = false
        notConfigured = false
        needsConsent = false
        cachedAt = nil
        self.bypassCache = bypassCache
        // The conversation was about the previous result; the draft is kept.
        followUps = []
        phase = .loading

        let captured = self.captured
        let plan = self.plan
        let useContext = settings.useContext
        translateTask = Task { [weak self] in
            do {
                let (client, config) = try TranslationService.activeClient()
                self?.providerLabel = config.model
                let cache = TranslationCache.shared
                switch plan.mode {
                case .word:
                    let context = useContext && captured.hasUsefulContext ? captured.context : nil
                    let key = TranslationCacheKey.word(text: captured.text, context: context, target: plan.direction.target,
                                                       native: plan.direction.native, model: config.model)
                    if !bypassCache,
                       let hit = cache.lookup(key, decode: { try JSONExtractor.decode(WordResult.self, from: $0) }) {
                        UsageTracker.recordCacheHit(provider: config, kind: .word)
                        self?.showWord(hit.value, cachedAt: hit.createdAt)
                        return
                    }
                    let request = Prompts.word(captured, direction: plan.direction, useContext: useContext)
                    let raw = try await client.complete(request)
                    try Task.checkCancellation()
                    let result = try JSONExtractor.decode(WordResult.self, from: raw)
                    cache.store(key, source: captured.text, payload: raw)
                    self?.showWord(result, cachedAt: nil)
                case .sentence:
                    let key = TranslationCacheKey.sentence(text: captured.text, target: plan.direction.target,
                                                           model: config.model)
                    if !bypassCache, let hit = cache.lookup(key, decode: { $0 }) {
                        UsageTracker.recordCacheHit(provider: config, kind: .translate)
                        self?.translation = hit.value
                        self?.cachedAt = hit.createdAt
                        self?.phase = .done
                        return
                    }
                    let request = Prompts.translation(captured, direction: plan.direction, useContext: useContext)
                    for try await delta in client.stream(request) {
                        guard let self else { return }
                        if self.phase == .loading { self.phase = .streaming }
                        self.translation += delta
                    }
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.translation = self.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.phase = .done
                    cache.store(key, source: captured.text, payload: self.translation)
                }
            } catch is CancellationError {
            } catch {
                if case LLMError.notConfigured = error { self?.notConfigured = true }
                if case LLMError.consentRequired = error { self?.needsConsent = true }
                if (error as? URLError)?.code == .cancelled { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func showWord(_ result: WordResult, cachedAt: Date?) {
        word = result
        translation = result.contextMeaning ?? ""
        self.cachedAt = cachedAt
        phase = .done
        autoSaveWord(result)
    }

    func toggleCapsule() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { capsuleExpanded.toggle() }
        if capsuleExpanded, keyItems == nil, !keyItemsPhase.isBusy { loadKeyItems() }
    }

    func loadKeyItems() {
        keyItemsTask?.cancel()
        keyItemsPhase = .loading
        let sentence = learningSentence
        let translation = learningTranslation
        let context = usedContext ? captured.context : nil
        let native = settings.targetLanguage
        let level = settings.learnerLevel
        let bypassCache = self.bypassCache
        keyItemsTask = Task { [weak self] in
            do {
                let (client, config) = try TranslationService.activeClient()
                let cache = TranslationCache.shared
                let key = TranslationCacheKey.keyItems(sentence: sentence, translation: translation, native: native,
                                                       level: level, model: config.model)
                let result: KeyItemsResult
                if !bypassCache,
                   let hit = cache.lookup(key, decode: { try JSONExtractor.decode(KeyItemsResult.self, from: $0) }) {
                    UsageTracker.recordCacheHit(provider: config, kind: .keyItems)
                    result = hit.value
                } else {
                    let raw = try await client.complete(Prompts.keyItems(sentence: sentence, translation: translation,
                                                                         context: context, native: native, level: level))
                    try Task.checkCancellation()
                    result = try JSONExtractor.decode(KeyItemsResult.self, from: raw)
                    cache.store(key, source: sentence, payload: raw)
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    self?.keyItems = result
                    self?.keyItemsPhase = .done
                }
                self?.autoSaveKeyItems(result.items ?? [])
            } catch is CancellationError {
            } catch {
                self?.keyItemsPhase = .failed(error.localizedDescription)
            }
        }
    }

    func loadAnalysis() {
        guard !analysisPhase.isBusy else { return }
        if analysis != nil {
            withAnimation { analysis = nil; analysisPhase = .idle }
            return
        }
        analysisPhase = .loading
        let sentence = learningSentence
        let translation = learningTranslation
        let hint = keyItems?.analysisHint
        let native = settings.targetLanguage
        let level = settings.learnerLevel
        let bypassCache = self.bypassCache
        analysisTask = Task { [weak self] in
            do {
                let (client, config) = try TranslationService.activeClient()
                let cache = TranslationCache.shared
                let key = TranslationCacheKey.analysis(sentence: sentence, translation: translation, hint: hint,
                                                       native: native, level: level, model: config.model)
                let result: SentenceAnalysis
                if !bypassCache,
                   let hit = cache.lookup(key, decode: { try JSONExtractor.decode(SentenceAnalysis.self, from: $0) }) {
                    UsageTracker.recordCacheHit(provider: config, kind: .analysis)
                    result = hit.value
                } else {
                    let raw = try await client.complete(Prompts.analysis(sentence: sentence, translation: translation,
                                                                         hint: hint, native: native, level: level))
                    try Task.checkCancellation()
                    result = try JSONExtractor.decode(SentenceAnalysis.self, from: raw)
                    cache.store(key, source: sentence, payload: raw)
                }
                withAnimation(.easeOut(duration: 0.2)) {
                    self?.analysis = result
                    self?.analysisPhase = .done
                }
            } catch is CancellationError {
            } catch {
                self?.analysisPhase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Follow-up questions

    func sendFollowUp() {
        guard canSendFollowUp else { return }
        let question = followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        followUpDraft = ""
        let turn = FollowUpTurn(question: question)
        followUps.append(turn)
        runFollowUp(turn.id)
    }

    func retryFollowUp(_ id: UUID) {
        guard canFollowUp, !isFollowUpBusy else { return }
        runFollowUp(id)
    }

    private func runFollowUp(_ id: UUID) {
        guard let index = followUps.firstIndex(where: { $0.id == id }) else { return }
        followUpTask?.cancel()
        followUps[index].answer = ""
        followUps[index].phase = .loading

        let history = followUps[..<index]
            .filter { $0.phase == .done }
            .suffix(followUpHistoryLimit)
            .map { Prompts.FollowUpExchange(question: $0.question, answer: $0.answer) }
        let material = Prompts.FollowUpMaterial(
            captured: captured, useContext: settings.useContext, direction: plan.direction,
            translation: translation, word: word,
            keyItems: capsuleExpanded ? keyItems?.items : nil, analysis: analysis)
        let request = Prompts.followUp(material, history: Array(history), question: followUps[index].question,
                                       native: settings.targetLanguage, level: settings.learnerLevel)
        followUpTask = Task { [weak self] in
            do {
                let (client, _) = try TranslationService.activeClient()
                // The request is tagged `.followUp`, so the client layer records it as 追问 on the usage page.
                // Follow-up answers are not cached: they depend on the whole conversation.
                for try await delta in client.stream(request) {
                    guard let self else { return }
                    self.updateFollowUp(id) { turn in
                        if turn.phase == .loading { turn.phase = .streaming }
                        turn.answer += delta
                    }
                }
                try Task.checkCancellation()
                self?.updateFollowUp(id) { turn in
                    turn.answer = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    turn.phase = .done
                }
            } catch is CancellationError {
            } catch {
                if (error as? URLError)?.code == .cancelled { return }
                self?.updateFollowUp(id) { $0.phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func updateFollowUp(_ id: UUID, _ change: (inout FollowUpTurn) -> Void) {
        guard let index = followUps.firstIndex(where: { $0.id == id }) else { return }
        change(&followUps[index])
    }

    func cancelAll() {
        translateTask?.cancel()
        keyItemsTask?.cancel()
        analysisTask?.cancel()
        followUpTask?.cancel()
    }

    // MARK: Vocabulary

    func isSaved(_ term: String) -> Bool { VocabularyStore.shared.contains(term) }

    func toggleSave(_ item: KeyItem) {
        let store = VocabularyStore.shared
        if store.contains(item.text) {
            store.remove(term: item.text)
        } else {
            store.add(term: item.text, phonetic: item.phonetic, kind: item.kind ?? "phrase", meaning: item.meaning ?? "",
                      note: item.note, sentence: learningSentence, sentenceTranslation: learningTranslation,
                      sourceApp: captured.appName)
        }
        objectWillChange.send()
    }

    func toggleSaveWord() {
        guard let word else { return }
        let term = word.lemma?.isEmpty == false ? word.lemma! : (word.term ?? sourceText)
        let store = VocabularyStore.shared
        if store.contains(term) {
            store.remove(term: term)
        } else {
            saveWord(word, term: term)
        }
        objectWillChange.send()
    }

    var wordTerm: String {
        guard let word else { return sourceText }
        return word.lemma?.isEmpty == false ? word.lemma! : (word.term ?? sourceText)
    }

    private func autoSaveWord(_ result: WordResult) {
        guard settings.autoAddWords, !plan.sourceIsNative else { return }
        saveWord(result, term: wordTerm)
        objectWillChange.send()
    }

    private func saveWord(_ result: WordResult, term: String) {
        let meaning = result.contextMeaning?.isEmpty == false
            ? result.contextMeaning!
            : (result.senses ?? []).compactMap { s in s.meaning.map { "\(s.pos ?? "") \($0)" } }.joined(separator: "；")
        // The entry is keyed by the lemma, so it needs the lemma's reading, not that of the inflected form selected.
        let isLemma = (result.lemma ?? "").isEmpty || result.lemma?.lowercased() == result.term?.lowercased()
        let phonetic = isLemma ? result.phonetic : result.lemmaPhonetic
        VocabularyStore.shared.add(term: term, phonetic: phonetic, kind: term.contains(" ") ? "phrase" : "word",
                                   meaning: meaning, note: result.note, sentence: result.example?.source,
                                   sentenceTranslation: result.example?.target, sourceApp: captured.appName)
    }

    private func autoSaveKeyItems(_ items: [KeyItem]) {
        guard settings.autoAddKeyItems else { return }
        for item in items where !(item.meaning ?? "").isEmpty {
            VocabularyStore.shared.add(term: item.text, phonetic: item.phonetic, kind: item.kind ?? "phrase",
                                       meaning: item.meaning ?? "", note: item.note, sentence: learningSentence,
                                       sentenceTranslation: learningTranslation, sourceApp: captured.appName)
        }
        objectWillChange.send()
    }
}
