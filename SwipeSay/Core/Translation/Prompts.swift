import Foundation

/// All prompts live here so they are easy to tune.
enum Prompts {
    /// Part of every translation-cache key. Bump it whenever a prompt changes in a way that should make
    /// previously cached results stale; old entries then simply stop matching and age out.
    static let version = 1

    struct Direction {
        var source: AppLanguage?
        var target: AppLanguage
        /// The user's own language — explanations are written in it.
        var native: AppLanguage
    }

    // MARK: Context block

    static func contextBlock(_ captured: CapturedText, useContext: Bool) -> String {
        var lines: [String] = []
        if let app = captured.appName { lines.append("Source app: \(app)") }
        if let title = captured.windowTitle, !title.isEmpty { lines.append("Window / document title: \(title)") }
        if useContext, captured.hasUsefulContext, let ctx = captured.context {
            lines.append("<context>\n\(ctx.trimmingCharacters(in: .whitespacesAndNewlines))\n</context>")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Sentence translation (streamed plain text)

    static func translation(_ captured: CapturedText, direction: Direction, useContext: Bool) -> LLMRequest {
        let system = """
        You are SwipeSay, an expert translator embedded in the user's operating system.
        Translate the text inside <selected> into \(direction.target.promptName).

        Rules:
        - The <context> block (if present) is the surrounding text the user was reading. Use it ONLY to resolve \
        ambiguity: pronoun references, polysemous words, domain terminology, tone and register. Never translate the context itself.
        - The selection may start or end mid-sentence; translate exactly the selected span, naturally, without adding words from the context.
        - Produce fluent, idiomatic \(direction.target.promptName) that a native speaker would write, faithful in meaning and tone.
        - Keep code, URLs, numbers, proper nouns and product names as appropriate. Preserve line breaks and list structure.
        - If the text came from OCR, silently fix obvious recognition errors and broken line wraps.
        - Output ONLY the translation. No quotes, no notes, no explanations.
        """
        var user = contextBlock(captured, useContext: useContext)
        if !user.isEmpty { user += "\n\n" }
        user += "<selected>\n\(captured.text)\n</selected>"
        return LLMRequest(system: system, user: user, maxTokens: 4096, kind: .translate)
    }

    // MARK: Word lookup (JSON)

    static func word(_ captured: CapturedText, direction: Direction, useContext: Bool) -> LLMRequest {
        let system = """
        You are SwipeSay, a bilingual learner's dictionary that understands context.
        The user selected a word or short phrase. Explain it for a \(direction.native.promptName) speaker, \
        translating into \(direction.target.promptName).

        Return ONLY a JSON object with these keys:
        {
          "term": "the selected word/phrase as written",
          "lemma": "dictionary form, e.g. 'run' for 'ran' (same as term if already base form)",
          "phonetic": "IPA for English like /rʌn/, pinyin for Chinese, empty string if not applicable",
          "context_meaning": "the precise meaning IN THIS CONTEXT, in \(direction.target.promptName), concise (<= 25 chars if Chinese)",
          "senses": [{"pos": "n. / v. / adj. …", "meaning": "common meanings in \(direction.target.promptName)"}],
          "example": {"source": "the sentence from the context containing the term (or a short natural example if no context)", \
        "target": "its translation in \(direction.target.promptName)"},
          "note": "one short, genuinely useful tip (collocation, confusable word, register) in \(direction.native.promptName); empty string if nothing valuable"
        }
        Rules: at most 4 senses, most common first; the context meaning must reflect the surrounding text, not just the most common sense.
        """
        var user = contextBlock(captured, useContext: useContext)
        if !user.isEmpty { user += "\n\n" }
        user += "<selected>\(captured.text)</selected>"
        return LLMRequest(system: system, user: user, expectsJSON: true, maxTokens: 1500, kind: .word)
    }

    // MARK: Capsule: key expressions + "is it worth analysing?" (JSON)

    static func keyItems(sentence: String, translation: String, context: String?, native: AppLanguage, level: LearnerLevel) -> LLMRequest {
        let system = """
        You are SwipeSay's language coach. The learner is \(level.promptDescription) whose native language is \(native.promptName).
        From the sentence in <sentence>, pick the expressions that are genuinely worth remembering for THIS learner.

        Selection rules:
        - Prefer multi-word units: phrasal verbs, collocations, idioms, fixed patterns, natural spoken chunks.
        - Include single words only if they are above the learner's level or used in a non-obvious sense here.
        - Skip anything the learner surely knows, names, numbers and filler. 0 items is a valid answer.
        - At most 6 items, ordered by usefulness. Use the form as it appears, or the base form for verbs/phrasal verbs.
        - "meaning" must fit this sentence, written in \(native.promptName); "note" is optional and short (usage, register, \
        a common mistake) — leave it empty unless it is truly helpful.

        Then decide whether a sentence analysis would really help. Set "analysis_worthy" to true ONLY if:
        (a) the structure is genuinely hard — long with nested clauses, inversion, ellipsis, fronting, participle / absolute \
        constructions, ambiguous attachment, unusual word order; OR
        (b) it is an everyday / conversational sentence whose natural meaning, tone or implied intent differs from a literal reading.
        Simple, transparent sentences → false. "analysis_hint" is a short phrase in \(native.promptName) saying what is worth \
        looking at (e.g. "倒装 + 非限定性定语从句" or "地道口语：委婉拒绝"), empty if false.

        Return ONLY JSON:
        {"items":[{"text":"...","kind":"word|phrase|phrasal_verb|collocation|idiom|pattern|slang","phonetic":"IPA or empty",\
        "meaning":"...","note":"..."}],"analysis_worthy":true|false,"analysis_hint":"..."}
        """
        var user = ""
        if let context, !context.isEmpty { user += "<context>\n\(context)\n</context>\n\n" }
        user += "<sentence>\n\(sentence)\n</sentence>\n<translation>\n\(translation)\n</translation>"
        return LLMRequest(system: system, user: user, expectsJSON: true, maxTokens: 2000, kind: .keyItems)
    }

    // MARK: On-demand sentence analysis (JSON)

    static func analysis(sentence: String, translation: String, hint: String?, native: AppLanguage, level: LearnerLevel) -> LLMRequest {
        let system = """
        You are SwipeSay's language coach. The learner is \(level.promptDescription), native language \(native.promptName).
        Explain the sentence in <sentence> the way a great teacher would: focus on what actually makes it hard or interesting, \
        not a mechanical label of every word. All explanations are in \(native.promptName).

        Choose the kind:
        - "structure" for structurally complex sentences: give the skeleton (core subject–verb–object, quoting the original words), \
        then break the sentence into meaningful chunks with their grammatical role and why they matter. Keep 3–7 chunks.
        - "expression" for everyday / conversational sentences: explain tone, implied meaning, when people say it, and \
        2–3 natural alternatives in "usage". Chunks may be empty.

        Return ONLY JSON:
        {
          "kind": "structure|expression",
          "skeleton": "core of the sentence using original words (empty for expression if not useful)",
          "skeleton_translation": "translation of the skeleton",
          "chunks": [{"text": "original span", "role": "e.g. 主语 / 谓语 / 宾语从句 / 非谓语作状语 / 插入语", "explain": "what it does / why"}],
          "insights": ["1–3 key takeaways: the real difficulty, a pattern to reuse, a trap to avoid"],
          "usage": "for expression: tone, context, alternatives; otherwise empty",
          "paraphrase": "the sentence rewritten in simpler words of the same language"
        }
        """
        var user = "<sentence>\n\(sentence)\n</sentence>\n<translation>\n\(translation)\n</translation>"
        if let hint, !hint.isEmpty { user += "\n<focus>\(hint)</focus>" }
        return LLMRequest(system: system, user: user, expectsJSON: true, maxTokens: 3000, kind: .analysis)
    }
}
