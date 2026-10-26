import Foundation
@testable import Mimidasu
import Testing

/// Tests `SessionClock` formatting/conversion and `SessionEntry`'s
/// precomputed display strings.
@Suite("Session models")
struct SessionModelsTests {

    // MARK: - Fixtures

    private let sampleRateSamples = 16000
    private let firstTranslationText = "Hello"
    private let secondTranslationText = "Hi"

    // MARK: - Helpers

    private func makeEntry() -> SessionEntry {
        let sentence = Sentence(index: 0, startS: 0, endS: 1, lang: "ja", text: "テスト")
        return SessionEntry(sentence: sentence)
    }

    // MARK: - SessionClock.seconds

    @Test("converts a sample count at the session rate to seconds")
    func sampleCountToSeconds() {
        let seconds = SessionClock.seconds(sampleRateSamples)

        #expect(seconds == 1.0)
    }

    @Test("half a second of samples converts to half a second")
    func halfSecondOfSamples() {
        let seconds = SessionClock.seconds(sampleRateSamples / 2)

        #expect(seconds == 0.5)
    }

    // MARK: - SessionClock.timestamp

    @Test("formats session seconds as a timestamp", arguments: [
        (seconds: 83.0, expected: "01:23"),
        (seconds: 3661.0, expected: "01:01:01"),
        (seconds: 3600.0, expected: "01:00:00"),
        (seconds: 3599.9, expected: "59:59"),
        (seconds: 83.9, expected: "01:23"),
        (seconds: -5.0, expected: "00:00")
    ])
    func timestampFormats(seconds: Double, expected: String) {
        let timestamp = SessionClock.timestamp(seconds)

        #expect(timestamp == expected)
    }

    // MARK: - Sentence

    @Test("a sentence's id mirrors its index")
    func sentenceIDMirrorsIndex() {
        let sentence = Sentence(index: 7, startS: 0, endS: 1, lang: "ja", text: "テスト")

        #expect(sentence.id == 7)
    }

    // MARK: - SessionEntry

    @Test("an untranslated entry has no joined translations")
    func untranslatedEntryHasNoTranslations() {
        let entry = makeEntry()

        #expect(entry.translations.isEmpty)
        #expect(entry.joinedTranslations == nil)
    }

    @Test("an entry precomputes its timestamps from the sentence")
    func entryPrecomputesTimestamps() {
        let sentence = Sentence(index: 3, startS: 0, endS: 61, lang: "ja", text: "テスト")

        let entry = SessionEntry(sentence: sentence)

        #expect(entry.startTimestamp == "00:00")
        #expect(entry.endTimestamp == "01:01")
    }

    @Test("an entry's id mirrors the sentence index")
    func entryIDMirrorsSentenceIndex() {
        let entry = makeEntry()

        #expect(entry.id == 0)
    }

    @Test("a single translation joins without a separator")
    func singleTranslationJoinsWithoutSeparator() {
        var entry = makeEntry()

        entry.replaceTranslation(SentenceTranslation(lang: "en", text: firstTranslationText))

        #expect(entry.joinedTranslations == firstTranslationText)
        #expect(entry.translations == [
            SentenceTranslation(lang: "en", text: firstTranslationText)
        ])
    }

    // MARK: - SessionEntry.replaceTranslation

    @Test("a re-translation for a new language appends instead of replacing")
    func replaceTranslationAppendsNewLanguage() {
        var entry = makeEntry()
        entry.replaceTranslation(SentenceTranslation(lang: "en", text: firstTranslationText))

        entry.replaceTranslation(SentenceTranslation(lang: "ko", text: "안녕"))

        #expect(entry.joinedTranslations == "\(firstTranslationText) / 안녕")
        #expect(entry.translations.count == 2)
    }

    /// The invariant that makes the retry safe: `replaceTranslation` is the
    /// entry's only mutator, so no number of repeats — a manual retry, an
    /// engine-swap replay, a duplicated delivery — can grow a second entry for
    /// a language the row already has.
    @Test("repeated results for one language never grow a second entry")
    func replaceTranslationIsIdempotentPerLanguage() {
        var entry = makeEntry()
        entry.replaceTranslation(SentenceTranslation(lang: "en", text: firstTranslationText))

        for text in ["Howdy", "Hiya", "Hello"] {
            entry.replaceTranslation(SentenceTranslation(lang: "en", text: text))
        }

        #expect(entry.translations == [SentenceTranslation(lang: "en", text: "Hello")])
        #expect(entry.joinedTranslations == "Hello")
    }

    /// Multi-target: the swap must hit the entry for the language being
    /// replaced, not the first one, so a second language can't be clobbered by
    /// a re-run of the first.
    @Test("replacing one language leaves the others untouched")
    func replaceTranslationSwapsTheMatchingLanguageOnly() {
        var entry = makeEntry()
        entry.replaceTranslation(SentenceTranslation(lang: "en", text: firstTranslationText))
        entry.replaceTranslation(SentenceTranslation(lang: "ko", text: secondTranslationText))

        entry.replaceTranslation(SentenceTranslation(lang: "en", text: "Howdy"))

        #expect(entry.translations == [
            SentenceTranslation(lang: "en", text: "Howdy"),
            SentenceTranslation(lang: "ko", text: secondTranslationText)
        ])
    }

    // MARK: - SessionEntry.translation(for:)

    @Test("translation(for:) returns the matching language's entry with its engine stamp")
    func translationForReturnsMatchingLanguage() {
        var entry = makeEntry()
        entry.replaceTranslation(
            SentenceTranslation(lang: "en", text: firstTranslationText, engine: .google)
        )
        entry.replaceTranslation(
            SentenceTranslation(lang: "ko", text: secondTranslationText, engine: .deepl)
        )

        let translation = entry.translation(for: "ko")

        #expect(translation == SentenceTranslation(lang: "ko", text: secondTranslationText, engine: .deepl))
    }

    @Test("translation(for:) returns nil for a language the entry doesn't hold")
    func translationForReturnsNilForMissingLanguage() {
        var entry = makeEntry()
        entry.replaceTranslation(SentenceTranslation(lang: "en", text: firstTranslationText))

        #expect(entry.translation(for: "ko") == nil)
    }

    @Test("translation(for:) reads the fresh text after a same-language replacement")
    func translationForReadsFreshText() {
        var entry = makeEntry()
        entry.replaceTranslation(SentenceTranslation(lang: "en", text: firstTranslationText))

        entry.replaceTranslation(SentenceTranslation(lang: "en", text: "Howdy"))

        #expect(entry.translation(for: "en") == SentenceTranslation(lang: "en", text: "Howdy"))
    }

    // MARK: - SentenceTranslation engine provenance

    @Test("old JSON without an engine field decodes with engine nil")
    func legacyJSONDecodesWithNilEngine() throws {
        let json = #"{"lang":"en","text":"Hello"}"#
        let data = try #require(json.data(using: .utf8))

        let translation = try JSONDecoder().decode(SentenceTranslation.self, from: data)

        #expect(translation == SentenceTranslation(lang: "en", text: "Hello"))
        #expect(translation.engine == nil)
    }

    @Test("a nil engine encodes as an absent key — old consumers stay compatible")
    func nilEngineEncodesAbsentKey() throws {
        let data = try JSONEncoder().encode(SentenceTranslation(lang: "en", text: "Hello"))

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["lang", "text"])
    }

    @Test("an engine stamp round-trips")
    func engineStampRoundTrips() throws {
        let original = SentenceTranslation(lang: "en", text: "Hello", engine: .deepl)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SentenceTranslation.self, from: data)

        #expect(decoded == original)
        #expect(decoded.engine == .deepl)
    }

    @Test("equal text from a different engine is a different value")
    func equalityIncludesEngine() {
        let unstamped = SentenceTranslation(lang: "en", text: "Hello")
        let stamped = SentenceTranslation(lang: "en", text: "Hello", engine: .deepl)

        #expect(unstamped != stamped)
        #expect(stamped == SentenceTranslation(lang: "en", text: "Hello", engine: .deepl))
    }
}
