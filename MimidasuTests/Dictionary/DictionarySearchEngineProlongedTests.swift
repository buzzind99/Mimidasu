@testable import Mimidasu
import Testing

/// The candidate shapes the prolonged-sound and script-switch probes add:
/// what a romaji query probes once the readings a ー hides ride the
/// variants, and the prefix-only switch probe a mixed-script reading is
/// reached by.
@Suite("DictionarySearchEngine prolonged candidates")
struct DictionarySearchEngineProlongedTests {

    @Test("a dash spelling probes the marked reading and both scripts of it")
    func prolongedCandidates() {
        // The typed letters land on the plain-vowel conversion; the reading
        // stores the mark, which arrives through the dash variant's mirror.
        let candidates = DictionarySearchEngine.headwordCandidates(for: "paatii", caseHeadwords: .empty)

        let texts = Set(candidates.map(\.text))

        #expect(texts.contains("ぱあてぃい"))
        #expect(texts.contains("ぱーてぃー"))
        #expect(texts.contains("パーティー"))
        #expect(candidates.filter { candidate in candidate.matchKind == .exact }
            .allSatisfy { candidate in candidate.probe == .exact })
    }

    @Test("a romaji query probes the script switches its conversion hides")
    func scriptSwitchCandidates() throws {
        let candidates = DictionarySearchEngine.headwordCandidates(
            for: "ubefurontiadaigaku", caseHeadwords: .empty
        )

        // The loanword variant うべふろんてぃあだいがく is the form whose
        // second position switches scripts, and うべフ agrees with the
        // stored reading on three scalars — everything after is prefix scan.
        let probe = try #require(candidates.first { candidate in candidate.text == "うべフ" })

        #expect(probe.probe == .prefix)
        #expect(probe.matchKind == .prefix)
    }
}
