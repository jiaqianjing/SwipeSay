import Foundation
import SwipeSayKit

/// Answers the Safari extension's requests with the same pipeline as the app (`PopupViewModel`: prompts, cache,
/// usage, auto-adding to the vocabulary). Native messages are request / response, so every request carries what
/// it needs (the selection, and for later steps the earlier result) and gets the finished result back.
@MainActor
enum WebBridge {
    struct Request: @unchecked Sendable {
        let raw: [String: Any]
        init(_ raw: [String: Any]) { self.raw = raw }

        var action: String { raw["action"] as? String ?? "" }
        func string(_ key: String) -> String? { raw[key] as? String }
        func object(_ key: String) -> [String: Any]? { raw[key] as? [String: Any] }
        func list(_ key: String) -> [[String: Any]] { raw[key] as? [[String: Any]] ?? [] }
    }

    static func handle(_ request: Request) async -> [String: Any] {
        // The app may have changed providers, consent or settings since this process started.
        AppSettings.shared.reloadFromStorage()
        ProviderStore.shared.reloadFromStorage()
        VocabularyStore.shared.reloadKeys()

        switch request.action {
        case "translate": return await translate(request)
        case "keyItems": return await keyItems(request)
        case "followUp": return await followUp(request)
        case "toggleSave": return toggleSave(request)
        case "grantConsent": return grantConsent(request)
        default: return ["ok": false, "error": "未知请求：\(request.action)"]
        }
    }

    // MARK: Actions

    private static func translate(_ request: Request) async -> [String: Any] {
        let model = makeModel(request)
        guard !model.sourceText.isEmpty else { return ["ok": false, "error": "没有选中文字。"] }
        model.start()
        await waitUntil { !model.phase.isBusy }
        guard model.phase == .done else { return failure(model, model.phase) }

        var reply: [String: Any] = [
            "ok": true,
            "mode": model.plan.mode == .word ? "word" : "sentence",
            "translation": model.translation,
            "provider": model.providerLabel,
            "cached": model.cachedAt != nil,
            "canCapsule": model.canShowCapsule,
            "usedContext": model.usedContext,
            "speechText": model.plan.mode == .word ? model.wordTerm : model.learningSentence,
            "speechLang": learningLanguage(model).speechCode,
        ]
        if let word = model.word, let encoded = encode(word) {
            reply["word"] = encoded
            reply["term"] = model.wordTerm
            reply["saved"] = model.isSaved(model.wordTerm)
        }
        return reply
    }

    private static func keyItems(_ request: Request) async -> [String: Any] {
        let model = makeModel(request)
        restoreResult(model, request)
        model.loadKeyItems()
        await waitUntil { !model.keyItemsPhase.isBusy }
        guard model.keyItemsPhase == .done else { return failure(model, model.keyItemsPhase) }
        let items: [[String: Any]] = (model.keyItems?.items ?? []).compactMap { item in
            guard var dict = encode(item) else { return nil }
            dict["kindLabel"] = item.kindLabel
            dict["saved"] = model.isSaved(item.text)
            return dict
        }
        return ["ok": true, "items": items]
    }

    private static func followUp(_ request: Request) async -> [String: Any] {
        let model = makeModel(request)
        restoreResult(model, request)
        model.followUps = request.list("history").compactMap { entry in
            guard let question = entry["q"] as? String, let answer = entry["a"] as? String else { return nil }
            var turn = PopupViewModel.FollowUpTurn(question: question)
            turn.answer = answer
            turn.phase = .done
            return turn
        }
        model.followUpDraft = request.string("question") ?? ""
        guard model.canSendFollowUp else { return ["ok": false, "error": "没有可以追问的内容。"] }
        model.sendFollowUp()
        await waitUntil { !model.isFollowUpBusy }
        guard let turn = model.followUps.last else { return ["ok": false, "error": "追问失败。"] }
        guard turn.phase == .done else { return failure(model, turn.phase) }
        return ["ok": true, "answer": turn.answer]
    }

    private static func toggleSave(_ request: Request) -> [String: Any] {
        let model = makeModel(request)
        restoreResult(model, request)
        if let raw = request.object("item"), let item = decode(KeyItem.self, from: raw) {
            model.toggleSave(item)
            return ["ok": true, "saved": model.isSaved(item.text)]
        }
        guard model.word != nil else { return ["ok": false, "error": "没有可以收藏的内容。"] }
        model.toggleSaveWord()
        return ["ok": true, "saved": model.isSaved(model.wordTerm)]
    }

    /// The panel's own consent screen (guideline 5.1.2(i)) names the provider and host; agreeing lands here.
    private static func grantConsent(_ request: Request) -> [String: Any] {
        guard let config = ProviderStore.shared.active, config.isReady else {
            return ["ok": false, "notConfigured": true, "error": "还没有配置模型服务。"]
        }
        guard request.string("providerID") == config.id.uuidString, request.string("host") == config.endpointHost else {
            return ["ok": false, "consent": consentDetails(for: config)]
        }
        AppSettings.shared.grantAIConsent(for: config)
        return ["ok": true]
    }

    private static func consentDetails(for config: ProviderConfig) -> [String: String] {
        ["providerID": config.id.uuidString, "provider": config.name, "host": config.endpointHost]
    }

    // MARK: Helpers

    private static func makeModel(_ request: Request) -> PopupViewModel {
        let text = (request.string("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let captured = CapturedText(text: text, context: request.string("context"), appName: "Safari",
                                    windowTitle: request.string("title"), origin: .selection)
        return PopupViewModel(captured: captured)
    }

    /// Puts back the result a previous `translate` returned, so key items, follow-ups and ★ work on it.
    private static func restoreResult(_ model: PopupViewModel, _ request: Request) {
        model.translation = request.string("translation") ?? ""
        if let raw = request.object("word") { model.word = decode(WordResult.self, from: raw) }
        model.phase = .done
    }

    private static func failure(_ model: PopupViewModel, _ phase: PopupViewModel.Phase) -> [String: Any] {
        var reply: [String: Any] = ["ok": false, "error": "请求超时，请重试。"]
        model.cancelAll()
        if case .failed(let message) = phase { reply["error"] = message }
        if model.notConfigured { reply["notConfigured"] = true }
        if model.needsConsent, let config = ProviderStore.shared.active {
            reply["consent"] = consentDetails(for: config)
        }
        return reply
    }

    /// The foreign-language side, which is what gets read aloud.
    private static func learningLanguage(_ model: PopupViewModel) -> AppLanguage {
        if model.plan.sourceIsNative { return model.plan.direction.target }
        return model.plan.direction.source ?? TranslationService.detectLanguage(model.sourceText) ?? .english
    }

    private static func waitUntil(timeout: Duration = .seconds(120), _ isDone: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !isDone(), ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(40))
            } catch {
                return
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
