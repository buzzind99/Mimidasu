import Foundation
@testable import Mimidasu
import Testing

/// Row expansion keyed by entry, not headword — the reported ポン bug: two
/// kana-only rows share one headword, so an expansion keyed on the headword
/// expanded a sibling with it, and the expanded block showed the lookup's
/// ranked-first entry instead of the row's own. Split from the parent suite to
/// keep both type bodies small; the fixture harness is the parent's, over its
/// own homograph words.
@MainActor
extension DictionarySearchStateTests {

    /// Two kana-only entries spelled ポン, the real database's shape (its
    /// pat/tap/clap and methamphetamine entries): one headword, two rows.
    private func makeHomographState() throws -> DictionarySearchStateFixture {
        try DictionarySearchStateFixture(extraWords: [
            JMDictFixtureDatabase.FixtureWord(
                id: "9994901",
                kanji: nil,
                kana: [JMDictFixtureDatabase.FixtureKana(
                    text: "ポン", common: false, appliesToKanji: nil, jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [JMDictFixtureDatabase.FixtureSense(
                    partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                    gloss: [JMDictFixtureDatabase.FixtureGloss(lang: "eng", text: "pat; tap; clap")]
                )]
            ),
            JMDictFixtureDatabase.FixtureWord(
                id: "9994902",
                kanji: nil,
                kana: [JMDictFixtureDatabase.FixtureKana(
                    text: "ポン", common: false, appliesToKanji: nil, jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [JMDictFixtureDatabase.FixtureSense(
                    partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                    gloss: [JMDictFixtureDatabase.FixtureGloss(lang: "eng", text: "methamphetamine")]
                )]
            )
        ])
    }

    @Test("two rows sharing a headword expand independently")
    func homographRowsExpandIndependently() async throws {
        let fixture = try makeHomographState()
        let state = fixture.state

        state.query = "ポン"
        #expect(await pollUntil { state.outcome.hits.count == 2 })
        let hits = state.outcome.hits
        // Both rows are kana-only ポン — one headword, two entries.
        #expect(hits.map(\.headword) == ["ポン", "ポン"])
        let firstKey = DictionarySearchState.lookupKey(for: hits[0])
        let secondKey = DictionarySearchState.lookupKey(for: hits[1])
        #expect(firstKey != secondKey)

        // The reported move: expanding the second row must leave its sibling
        // above collapsed.
        state.lookupState.toggle(
            key: secondKey, candidate: LookupCandidate(text: "ポン", reading: "ポン")
        )

        #expect(state.lookupState.isExpanded(key: secondKey))
        #expect(!state.lookupState.isExpanded(key: firstKey))
    }

    @Test("an untouched row opens on its own entry, not the lookup's ranked lead")
    func rowOpensOnItsOwnEntry() async throws {
        let fixture = try makeHomographState()
        let state = fixture.state

        state.query = "ポン"
        #expect(await pollUntil { state.outcome.hits.count == 2 })
        let hits = state.outcome.hits
        // The lookup both rows run, ranked the way the engine ranks one: the
        // lower entry id leads, so the second row's own entry sits at 1.
        let shared = LookupResult(
            matched: "ポン",
            entries: [searchEntry(seq: 9_994_901), searchEntry(seq: 9_994_902)]
        )
        let secondKey = DictionarySearchState.lookupKey(for: hits[1])
        let fallback = DictionarySearchState.rowEntryIndex(for: hits[1], in: shared)

        #expect(fallback == 1)
        #expect(state.validatedIndex(for: secondKey, in: shared, fallback: fallback) == 1)

        // A pager touch stores the absolute page, which wins from then on.
        state.stepEntry(secondKey, to: 0, in: shared)
        #expect(state.validatedIndex(for: secondKey, in: shared, fallback: fallback) == 0)
    }
}
