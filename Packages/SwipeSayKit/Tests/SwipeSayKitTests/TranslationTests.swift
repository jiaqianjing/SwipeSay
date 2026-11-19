import XCTest
@testable import SwipeSayKit

final class TranslationModeTests: XCTestCase {
    func testShortSelectionsAreWords() {
        XCTAssertEqual(TranslationService.mode(for: "ubiquitous"), .word)
        XCTAssertEqual(TranslationService.mode(for: "set foot in"), .word)
        XCTAssertEqual(TranslationService.mode(for: "  pick up \n"), .word)
        XCTAssertEqual(TranslationService.mode(for: "书"), .word)
    }

    func testSentencesAndLongTextAreSentences() {
        XCTAssertEqual(TranslationService.mode(for: "She left."), .sentence)
        XCTAssertEqual(TranslationService.mode(for: "No sooner had she set foot in the house than she felt it"), .sentence)
        XCTAssertEqual(TranslationService.mode(for: "line one\nline two"), .sentence)
        XCTAssertEqual(TranslationService.mode(for: "这是一个完整的句子"), .sentence)
        XCTAssertEqual(TranslationService.mode(for: ""), .sentence)
    }

    func testLanguageDetection() {
        XCTAssertEqual(TranslationService.detectLanguage("hello world"), .english)
        // Single Russian words used to be taken for Bulgarian or Ukrainian.
        XCTAssertEqual(TranslationService.detectLanguage("книга"), .russian)
        XCTAssertEqual(TranslationService.detectLanguage("молоко"), .russian)
    }

    func testChineseVariantsCountAsTheSameLanguage() {
        XCTAssertTrue(TranslationService.sameLanguage(.traditionalChinese, .simplifiedChinese))
        XCTAssertFalse(TranslationService.sameLanguage(.english, .simplifiedChinese))
        XCTAssertFalse(TranslationService.sameLanguage(nil, .english))
    }
}

final class ModelOutputTests: XCTestCase {
    func testJSONExtractorToleratesFencesAndChatter() throws {
        let raw = """
        Sure! Here it is:
        ```json
        {"term":"ubiquitous","context_meaning":"无处不在的","senses":[{"pos":"adj.","meaning":"普遍存在的"}]}
        ```
        """
        let word = try JSONExtractor.decode(WordResult.self, from: raw)
        XCTAssertEqual(word.term, "ubiquitous")
        XCTAssertEqual(word.contextMeaning, "无处不在的")
        XCTAssertEqual(word.senses?.first?.pos, "adj.")
    }

    func testJSONExtractorThrowsOnGarbage() {
        XCTAssertThrowsError(try JSONExtractor.decode(WordResult.self, from: "no json here"))
    }

    func testWordResultRoundTripsWithSnakeCaseKeys() throws {
        let word = WordResult(term: "книги", lemma: "книга", phonetic: "кни́ги", lemmaPhonetic: "кни́га",
                              contextMeaning: "书（复数）", senses: [.init(pos: "名", meaning: "书")])
        let data = try JSONEncoder().encode(word)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"lemma_phonetic\""))
        XCTAssertTrue(json.contains("\"context_meaning\""))
        XCTAssertEqual(try JSONDecoder().decode(WordResult.self, from: data), word)
    }

    func testStressMarkedSpellingReplacesTheHeadword() {
        XCTAssertTrue(Phonetic.isMarkedSpelling("молоко́", of: "молоко"))
        XCTAssertFalse(Phonetic.isMarkedSpelling("/juːˈbɪkwɪtəs/", of: "ubiquitous"))
        XCTAssertFalse(Phonetic.isMarkedSpelling("молоко", of: "молоко"))
        // ё is ordinary spelling, not a stress mark.
        XCTAssertEqual(Phonetic.stripMarks("ещё"), "ещё")
    }

    func testKeyItemKindLabels() {
        XCTAssertEqual(KeyItem(text: "set foot in", kind: "phrasal_verb").kindLabel, "词组")
        XCTAssertEqual(KeyItem(text: "no sooner … than", kind: "pattern").kindLabel, "句型")
        XCTAssertEqual(KeyItem(text: "x", kind: nil).kindLabel, "表达")
    }
}

final class CacheKeyTests: XCTestCase {
    func testSameRequestGivesSameKey() {
        let a = TranslationCacheKey.sentence(text: "Hello there.", target: .simplifiedChinese, model: "gpt-5-mini")
        let b = TranslationCacheKey.sentence(text: "Hello there.", target: .simplifiedChinese, model: "gpt-5-mini")
        XCTAssertEqual(a, b)
    }

    func testTargetAndModelAreDistinguished() {
        let base = TranslationCacheKey.sentence(text: "Hello there.", target: .simplifiedChinese, model: "gpt-5-mini")
        XCTAssertNotEqual(base, TranslationCacheKey.sentence(text: "Hello there.", target: .japanese, model: "gpt-5-mini"))
        XCTAssertNotEqual(base, TranslationCacheKey.sentence(text: "Hello there.", target: .simplifiedChinese, model: "claude-haiku-5-5"))
        XCTAssertNotEqual(base, TranslationCacheKey.word(text: "Hello there.", context: nil, target: .simplifiedChinese,
                                                         native: .simplifiedChinese, model: "gpt-5-mini"))
    }

    func testAgeLabel() {
        let now = Date()
        XCTAssertEqual(TranslationCachePolicy.age(since: now.addingTimeInterval(-10), now: now), "刚刚")
    }
}
