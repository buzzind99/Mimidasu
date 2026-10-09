import Foundation
@testable import Mimidasu
import Testing

// MARK: - Live database

/// Exercises the real prepared JMDict database when one resolves (the
/// Application Support location, or — debug checkouts — the uncompressed
/// intermediate `scripts/build_dictionary.sh` leaves in `build/`). Opt-in like
/// the other `Live*` suites: it re-runs at every pin bump and pins the
/// spot entries against the shipped data shape.
/// Same resolution chain as `JMDictLookup.defaultDatabaseURL`, with a
/// repo-root fallback the test host's working directory can't provide.
/// File-scope so the suite trait can gate on it.
private let liveDatabaseURL: URL? = {
    if let resolved = JMDictLookup.defaultDatabaseURL {
        return resolved
    }
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let checkout = repoRoot.appendingPathComponent("build/\(JMDictPin.preparedFileName)")
    return FileManager.default.fileExists(atPath: checkout.path) ? checkout : nil
}()

@Suite("JMDictLookup live database", .enabled(if: liveDatabaseURL != nil))
struct JMDictLookupLiveTests {
    private let engine: JMDictLookup

    init() throws {
        let url = try #require(liveDatabaseURL)
        engine = JMDictLookup(resolveDatabase: { url })
    }

    @Test("hits 食べる with its pitch and JLPT from the real database")
    func taberu() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "食べる")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 1_358_280)
        #expect(entry.common)
        #expect(entry.jlpt == 5)
        #expect(entry.zoPatts == "LHLL")
        #expect(entry.senses[0].glosses == ["to eat"])
    }

    @Test("inherits 喰べる's pitch from the たべる row its furigana names")
    func kuberuInheritsPitch() throws {
        // The rt-omitted furigana shape: the okurigana pieces carry no rt,
        // so only the ruby fallback rejoins the reading たべる the pitch
        // inheritance matches on.
        let result = try #require(try engine.lookup(LookupCandidate(text: "喰べる")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 1_358_280)
        #expect(entry.hatsuon == "た~べる")
        #expect(entry.accPatts == "2")
        #expect(entry.zoPatts == "LHLL")
    }

    @Test("inherits お土産's pitch from the おみやげ row its furigana names")
    func omiyageInheritsPitch() throws {
        // The leading-rt-omitted shape: お opens the furigana with no rt, so
        // the ruby fallback restores the おみやげ reading the match needs.
        let result = try #require(try engine.lookup(LookupCandidate(text: "お土産")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 1_002_500)
        #expect(entry.hatsuon == "お･みやげ")
        #expect(entry.accPatts == "0")
        #expect(entry.zoPatts == "LHHHH")
    }

    @Test("hits the kana-only gairaigo アルバイト from the real database")
    func arubaito() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "アルバイト")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 1_019_420)
        #expect(entry.keb == nil)
        #expect(entry.common)
        #expect(entry.jlpt == 4)
    }

    @Test("hits 橋 with its pitch from the real database")
    func hashi() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "橋")))

        let entry = try #require(result.entries.first)

        #expect(entry.entSeq == 1_237_410)
        #expect(entry.common)
        #expect(entry.jlpt == 5)
        #expect(entry.zoPatts == "HLL")
    }

    @Test("returns multiple homograph entries for あめ in ranked order")
    func ameHomographs() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "あめ")))

        #expect(result.entries.count >= 2)
        #expect(result.entries.first?.common == true)
    }

    @Test("ranks the 前/まえ entry first when the furigana reading is まえ")
    func maeReadingMatch() throws {
        let result = try #require(try engine.lookup(
            LookupCandidate(text: "前", reading: "まえ")
        ))

        #expect(result.entries.count >= 2)
        #expect(result.entries.first?.reb == "まえ")
    }

    @Test("ranks the kana-only さ entry first when the tap is kana")
    func kanaSurfaceRanksFirstLive() throws {
        let result = try #require(try engine.lookup(LookupCandidate(text: "さ")))

        #expect(result.entries.first?.entSeq == 2_029_120)
        #expect(result.entries.first?.keb == nil)
    }

    @Test("reading resolves a standalone kanji IPADIC lacks (圧 → あつ)")
    func readingForStandaloneKanji() throws {
        let reading = try #require(try engine.reading(forWriting: "圧"))

        #expect(reading == "あつ")
    }

    @Test("the fullwidth initialism lookup resolves against the shipped normalized rows",
          arguments: ["ＴＫＧ", "TKG"])
    func fullwidthInitialismLive(text: String) throws {
        // The shipped entry (ent_seq 2834407) ingests as keb TKG; the
        // search row's expand hands the lookup the raw stored headword, and
        // a fullwidth tap folds onto the same row. Before ingestion
        // normalized, both resolved notFound — the "No dictionary entry"
        // card under a found search hit.
        let result = try #require(try engine.lookup(LookupCandidate(text: text)))
        let entry = try #require(result.entries.first { candidate in
            candidate.entSeq == 2_834_407
        })

        #expect(entry.keb == "TKG")
        #expect(entry.reb == "ティー・ケー・ジー")
    }
}
