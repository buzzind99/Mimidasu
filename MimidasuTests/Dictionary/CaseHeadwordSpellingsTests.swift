import Foundation
@testable import Mimidasu
import Testing

/// The side set the search engine keeps beside its handle: every stored
/// spelling that is not already lowercase, ordered by the form a query folds
/// into before it can reach it.
///
/// Driven through `init(spellings:)` rather than a database — the seam folds
/// and sorts exactly as the load does, so these are assertions about the
/// matching rules, not about a corpus.
@Suite("Case-bearing headword spellings")
struct CaseHeadwordSpellingsTests {
    private let mixed = CaseHeadwordSpellings(spellings: ["ActiveX", "iPhone", "TKG"])

    @Test("reports a stored spelling whose fold is the query as an exact match")
    func foldedQueryIsExact() throws {
        let match = try #require(mixed.matches(openingFold: "activex").first)

        #expect(match == CaseHeadwordSpellings.Match(spelling: "ActiveX", isExact: true))
    }

    @Test("reports a stored spelling the query merely opens as a prefix match")
    func openedSpellingIsPrefix() throws {
        let match = try #require(mixed.matches(openingFold: "iphon").first)

        #expect(match == CaseHeadwordSpellings.Match(spelling: "iPhone", isExact: false))
    }

    @Test("leaves the all-caps spelling to the query's own uppercase probe")
    func allCapsSpellingFoldsToItself() throws {
        let match = try #require(mixed.matches(openingFold: "tkg").first)

        #expect(match == CaseHeadwordSpellings.Match(spelling: "TKG", isExact: true))
    }

    @Test("keeps every spelling that folds to the same form")
    func foldCollisionsAllSurvive() {
        // Two stored spellings of one headword whose case differs entirely. A
        // set that kept only the first would answer the query with the first's
        // row and never with its own — and the order they come back in has to
        // be fixed, because Swift's sort is not stable.
        let set = CaseHeadwordSpellings(spellings: ["ActiveX", "ACTIVEX"])

        let spellings = set.matches(openingFold: "activex").map(\.spelling)

        #expect(spellings == ["ACTIVEX", "ActiveX"])
    }

    @Test("folds a fullwidth query onto the stored spelling's form")
    func fullwidthQueryFoldsOnto() throws {
        let set = CaseHeadwordSpellings(spellings: ["ＴＫＧ"])

        let match = try #require(set.matches(openingFold: "tkg").first)

        #expect(match.isExact)
    }

    @Test("matches nothing for an empty query")
    func emptyQueryMatchesNothing() {
        #expect(mixed.matches(openingFold: "").isEmpty)
    }

    @Test("matches nothing when the set is empty")
    func emptySetMatchesNothing() {
        #expect(CaseHeadwordSpellings.empty.matches(openingFold: "activex").isEmpty)
    }

    @Test("matches nothing when the query sorts past every fold")
    func pastEndQueryMatchesNothing() {
        // Both binary searches return `folds.count` and the range comes back
        // empty — the boundary the `end > start` guard exists for.
        #expect(mixed.matches(openingFold: "zzz").isEmpty)
    }

    @Test("does not reach a spelling the query does not open")
    func unopenedSpellingIsNotAMatch() {
        // `iPad` sits in the same folded order as `iPhone`; a set that treated
        // its range as its answer would hand the wrong row to a query that
        // opens neither.
        let set = CaseHeadwordSpellings(spellings: ["iPad", "iPhone"])

        #expect(set.matches(openingFold: "iph").map(\.spelling) == ["iPhone"])
    }

    // MARK: Candidate shape

    @Test("probes a folded spelling as both an exact seek and a prefix scan")
    func foldedSpellingProbesBothTiers() {
        let candidates = DictionarySearchEngine.literalCandidates(
            for: "activex", caseHeadwords: mixed
        )

        let spelling = candidates.filter { candidate in candidate.text == "ActiveX" }

        #expect(spelling.count == 2)
        #expect(spelling.map(\.probe) == [.exact, .prefix])
        #expect(spelling.map(\.matchKind) == [.exact, .prefix])
        #expect(spelling.allSatisfy { candidate in candidate.highlightScalars == 7 })
    }

    @Test("probes a spelling the query only opens as a prefix scan alone")
    func openedSpellingProbesPrefixAlone() {
        let candidates = DictionarySearchEngine.literalCandidates(
            for: "iphon", caseHeadwords: mixed
        )

        let spelling = candidates.filter { candidate in candidate.text == "iPhone" }

        #expect(spelling.count == 1)
        #expect(spelling.first?.probe == .prefix)
        #expect(spelling.first?.matchKind == .prefix)
    }

    @Test("does not repeat a spelling the query's own uppercase probe already carries")
    func noDuplicateProbes() {
        // `TKG` is the one spelling the literal candidates reach without the
        // set, and it is in the set too. A second seek for it would spend
        // real time proving what the first one knew.
        let candidates = DictionarySearchEngine.literalCandidates(
            for: "tkg", caseHeadwords: mixed
        )

        let tkg = candidates.filter { candidate in candidate.text == "TKG" }

        #expect(tkg.count == 2)
        #expect(Set(tkg.map(\.probe)) == [.exact, .prefix])
    }

    @Test("a kana query opens none of the Latin folds, so the two never collide")
    func japaneseQueryIsUnaffected() {
        // The set answers only where the folds actually agree: a pure-kana
        // query opens none of these Latin folds, so the Japanese branch's
        // rescue emits nothing and its candidate set stays exactly what it
        // was without the set.
        let candidates = DictionarySearchEngine.headwordCandidates(
            for: "たべる", caseHeadwords: mixed
        )

        #expect(Set(candidates.map(\.text)) == ["たべる", "タベル", "たベ", "タべ", "たべル", "タベる"])
    }

    @Test("probes the spelling from the Japanese branch when the query mixes scripts")
    func mixedScriptCaseCandidates() {
        // `ABC順` arrives normalized as `abc順`, and the Japanese branch
        // returns before the literal spellings are ever built — without the
        // shared rescue both of its probes miss: the exact seek asks for
        // `abc順`, and the B-tree's BINARY order puts `ABC順` outside the
        // `abc順` range.
        let candidates = DictionarySearchEngine.headwordCandidates(
            for: "abc順", caseHeadwords: CaseHeadwordSpellings(spellings: ["ABC順"])
        )

        let spelling = candidates.filter { candidate in candidate.text == "ABC順" }

        #expect(spelling.map(\.probe) == [.exact, .prefix])
        #expect(spelling.map(\.matchKind) == [.exact, .prefix])
        #expect(spelling.allSatisfy { candidate in candidate.highlightScalars == 4 })
        // The query's own probes ride beside the rescue, unchanged.
        #expect(
            candidates.filter { candidate in candidate.text == "abc順" }.map(\.probe)
                == [.exact, .prefix]
        )
    }
}
