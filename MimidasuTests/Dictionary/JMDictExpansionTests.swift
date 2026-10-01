import Foundation
@testable import Mimidasu
import Testing

/// The pure forward-expansion candidate builder: join rules, adjacency
/// validation against the sentence text, caps, and candidate ordering.
@Suite("JMDictExpansion candidates")
final class JMDictExpansionCandidateTests {
    private func segments(_ pairs: (surface: String, lemma: String?)...) -> [LookupSegment] {
        pairs.map { pair in LookupSegment(surface: pair.surface, lemma: pair.lemma) }
    }

    @Test("joins forward segments longest-first behind the tapped candidate")
    func compoundJoin() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "お土産"
        )

        #expect(candidates.map(\.candidate.text) == ["お", "お土産"])
    }

    @Test("a tap mid-sentence expands forward only")
    func forwardOnly() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 1,
            sentenceText: "お土産"
        )

        // The kanji splits trail (the 土産 surface itself is deduplicated).
        #expect(candidates.map(\.candidate.text) == ["土産", "土", "産"])
    }

    @Test("the surface leads the lemma for the single-token candidates")
    func surfaceFirstPreference() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("食べ", "食べる"), ("ま", nil), ("した", nil)),
            tappedAt: 0,
            sentenceText: "食べました"
        )

        // The tapped surface leads, the lemma follows as the miss fallback
        // (the potential-shaped tail adds the unwrapped 食ぶ), the joins
        // come longest-first, and the kanji split trails them all.
        #expect(candidates.map(\.candidate.text) == [
            "食べ", "食べる", "食ぶ", "食べました", "食べま", "食"
        ])
    }

    @Test("a surface that is itself a headword leads its lemma (な tap shows な, not だ)")
    func surfaceLeadsCopulaLemma() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("な", "だ")),
            tappedAt: 0,
            sentenceText: "な"
        )

        #expect(candidates.map(\.candidate.text) == ["な", "だ"])
    }

    @Test("the join walk stops at the segment cap, never past the candidate cap")
    func candidateCap() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(
                ("あ", nil), ("い", nil), ("う", nil), ("え", nil),
                ("お", nil), ("か", nil), ("き", nil), ("く", nil)
            ),
            tappedAt: 0,
            sentenceText: "あいうえおかきく"
        )

        // Six joined segments at most — the two trailing ones stay one tap
        // away — so the list lands well under the candidate cap.
        #expect(candidates.map(\.candidate.text) == [
            "あ", "あいうえおか", "あいうえお", "あいうえ", "あいう", "あい"
        ])
    }

    @Test("the widest join walk still leaves the splits room under the cap")
    func joinsAndSplitsShareTheCap() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(
                ("東京駅前", nil), ("あ", nil), ("い", nil),
                ("う", nil), ("え", nil), ("お", nil)
            ),
            tappedAt: 0,
            sentenceText: "東京駅前あいうえお"
        )

        // The tapped surface and its five joins fill the slots ahead of the
        // splits, which truncate at the candidate cap.
        #expect(candidates.map(\.candidate.text) == [
            "東京駅前", "東京駅前あいうえお", "東京駅前あいうえ", "東京駅前あいう",
            "東京駅前あい", "東京駅前あ", "東京駅", "京駅前", "東京"
        ])
        #expect(candidates.count == JMDictExpansion.maxCandidates)
    }

    @Test("skips whitespace-only segments and still joins across them")
    func whitespaceGapJoins() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), (" ", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "お 土産"
        )

        #expect(candidates.map(\.candidate.text) == ["お", "お土産"])
    }

    @Test("a non-whitespace gap in the sentence text stops expansion")
    func punctuationGapStopsExpansion() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "お、土産"
        )

        #expect(candidates.map(\.candidate.text) == ["お"])
    }

    @Test("a punctuation-only segment stops expansion")
    func punctuationSegmentStopsExpansion() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("本", nil), ("、", nil), ("読む", "読む")),
            tappedAt: 0,
            sentenceText: "本、読む"
        )

        #expect(candidates.map(\.candidate.text) == ["本"])
    }

    @Test("a numeral-run segment stops expansion")
    func numeralRunStopsExpansion() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("本", nil), ("3", nil), ("冊", nil)),
            tappedAt: 0,
            sentenceText: "本 3冊"
        )

        #expect(candidates.map(\.candidate.text) == ["本"])
    }

    @Test("an overridden-particle segment stops expansion")
    func particleStopsExpansion() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("で", nil), ("は", "は")),
            tappedAt: 0,
            sentenceText: "では"
        )

        #expect(candidates.map(\.candidate.text) == ["で"])
    }

    @Test("does not duplicate the single candidate when the lemma equals the surface")
    func lemmaSurfaceDeduplicated() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("土産", "土産")),
            tappedAt: 0,
            sentenceText: "土産"
        )

        // The split matching the surface is deduplicated; the shorter
        // substrings trail.
        #expect(candidates.map(\.candidate.text) == ["土産", "土", "産"])
    }

    @Test("an out-of-bounds tap index yields no candidates")
    func outOfBoundsIndex() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("あ", nil)),
            tappedAt: 5,
            sentenceText: "あ"
        )

        #expect(candidates.isEmpty)
    }

    @Test("a sentence text that has drifted away from the segments fails closed")
    func driftedSentenceTextFailsClosed() {
        // The surfaces no longer sit where the sentence text has them: no
        // join candidate is produced, the tapped segment still queries.
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "違う文です"
        )

        #expect(candidates.map(\.candidate.text) == ["お"])
    }

    @Test("a join member past the sentence end stops expansion")
    func whitespaceRunPastSentenceEndStopsExpansion() {
        // The sentence text ends right after the tapped surface, so the
        // anchor degrades to the start; the scan for い crosses the trailing
        // full-width space and runs off the end without matching.
        let candidates = JMDictExpansion.candidates(
            segments: segments(("あ", nil), ("い", nil)),
            tappedAt: 0,
            sentenceText: "あ\u{3000}"
        )

        #expect(candidates.map(\.candidate.text) == ["あ"])
    }

    // MARK: Kanji splits

    @Test("a multi-kanji surface splits into per-kanji candidates behind it")
    func kanjiSplit() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("映画", nil)),
            tappedAt: 0,
            sentenceText: "映画"
        )

        // The longest split (映画) is the surface itself and is deduplicated.
        #expect(candidates.map(\.candidate.text) == ["映画", "映", "画"])
    }

    @Test("kana breaks a kanji run: only the runs split, longest substrings first")
    func kanaBreaksRuns() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("食べ物", nil)),
            tappedAt: 0,
            sentenceText: "食べ物"
        )

        #expect(candidates.map(\.candidate.text) == ["食べ物", "食", "物"])
    }

    @Test("substring splits honor the split-length cap and the candidate cap")
    func splitLengthCap() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("東京駅前", nil)),
            tappedAt: 0,
            sentenceText: "東京駅前"
        )

        // Length-3 substrings, then 2, then 1 — truncated at the candidate
        // cap before the single-kanji tail completes.
        #expect(candidates.map(\.candidate.text) == [
            "東京駅前", "東京駅", "京駅前", "東京", "京駅", "駅前", "東", "京", "駅"
        ])
    }

    @Test("single-kanji and kana-only surfaces emit no split candidates")
    func noSplitsForSingleKanjiAndKana() {
        // A single-kanji surface's only substring is itself (deduplicated).
        #expect(JMDictExpansion.candidates(
            segments: segments(("本", nil)), tappedAt: 0, sentenceText: "本"
        ).map(\.candidate.text) == ["本"])
        #expect(JMDictExpansion.candidates(
            segments: segments(("あめ", nil)), tappedAt: 0, sentenceText: "あめ"
        ).map(\.candidate.text) == ["あめ"])
    }

    @Test("split candidates carry no reading and derive the kanji kind")
    func splitCandidatesCarryNoReading() {
        let candidates = JMDictExpansion.candidates(
            segments: [LookupSegment(surface: "映画", reading: "えいが")],
            tappedAt: 0,
            sentenceText: "映画"
        )

        let splits = candidates.dropFirst()

        #expect(splits.map(\.candidate.text) == ["映", "画"])
        #expect(splits.map(\.candidate.reading).allSatisfy { reading in reading == nil })
        #expect(splits.map(\.candidate.kind).allSatisfy { kind in kind == .kanji })
    }

    @Test("splits trail the joins and never duplicate an earlier candidate")
    func splitsTrailJoinsDeduplicated() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("生徒", "生徒"), ("会", "会")),
            tappedAt: 0,
            sentenceText: "生徒会"
        )

        // The join comes before the splits; the 生徒 split (the surface
        // itself) is deduplicated away and the joined text contributes the
        // boundary-crossing 徒会 (the neighbor's 会 stays one tap away).
        #expect(candidates.map(\.candidate.text) == ["生徒", "生徒会", "生", "徒", "徒会"])
    }

    @Test("the joined text's boundary-crossing splits trail the tapped surface's")
    func joinedTextSplitsAfterTappedSplits() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("風呂", nil), ("敷", nil)),
            tappedAt: 0,
            sentenceText: "風呂敷"
        )

        // The tapped surface's splits (風, 呂) lead; the joined text adds
        // only the boundary-crossing 呂敷 — the neighbor's 敷 stays one
        // tap away on the 敷 segment, and the join itself deduplicates.
        #expect(candidates.map(\.candidate.text) == ["風呂", "風呂敷", "風", "呂", "呂敷"])
    }

    @Test("a kana tap gains no boundary-crossing splits across a kanji neighbor")
    func kanaTapNoCrossingSplits() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("お", nil), ("土産", "土産")),
            tappedAt: 0,
            sentenceText: "お土産"
        )

        // The kanji run starts inside the neighbor, so no substring of
        // お土産 straddles the tap boundary: the join alone remains.
        #expect(candidates.map(\.candidate.text) == ["お", "お土産"])
    }

    @Test("joined-text splits truncate behind the tapped surface's under the cap")
    func joinedSplitsTruncatedBehindTappedSplits() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("東京駅前", nil), ("駅", nil)),
            tappedAt: 0,
            sentenceText: "東京駅前駅"
        )

        // The join itself occupies a candidate slot (longest-first joins
        // rank above splits), so the tapped surface's eight splits leave
        // one slot and the joined text's boundary-crossing splits fall to
        // the cap before emitting.
        #expect(candidates.map(\.candidate.text) == [
            "東京駅前", "東京駅前駅", "東京駅", "京駅前", "東京", "京駅", "駅前", "東", "京"
        ])
    }

    // MARK: Reading threading

    @Test("joins concatenate member readings; the single candidate keeps the tap's")
    func readingThreading() {
        let candidates = JMDictExpansion.candidates(
            segments: [
                LookupSegment(surface: "前", reading: "まえ"),
                LookupSegment(surface: "の", reading: "の")
            ],
            tappedAt: 0,
            sentenceText: "前の"
        )

        #expect(candidates.map(\.candidate.text) == ["前", "前の"])
        #expect(candidates.map(\.candidate.reading) == ["まえ", "まえの"])
    }

    @Test("a join member without a reading drops the joined reading")
    func joinedReadingDroppedWhenPartial() {
        let candidates = JMDictExpansion.candidates(
            segments: [
                LookupSegment(surface: "前", reading: "まえ"),
                LookupSegment(surface: "の")
            ],
            tappedAt: 0,
            sentenceText: "前の"
        )

        #expect(candidates.map(\.candidate.text) == ["前", "前の"])
        #expect(candidates[0].candidate.reading == "まえ")
        #expect(candidates[1].candidate.reading == nil)
    }

    @Test("a lemma candidate carries the tapped segment's reading")
    func lemmaCandidateCarriesReading() {
        let candidates = JMDictExpansion.candidates(
            segments: [
                LookupSegment(surface: "食べ", lemma: "食べる", reading: "たべ"),
                LookupSegment(surface: "ま", reading: "ま"),
                LookupSegment(surface: "した", reading: "した")
            ],
            tappedAt: 0,
            sentenceText: "食べました"
        )

        #expect(candidates[0].candidate.text == "食べ")
        #expect(candidates[0].candidate.reading == "たべ")
        #expect(candidates[1].candidate.text == "食べる")
        #expect(candidates[1].candidate.reading == "たべ")
    }

    @Test("candidates carry the expansion origin in build order")
    func originTagging() {
        let candidates = JMDictExpansion.candidates(
            segments: segments(("食べ", "食べる"), ("ま", nil), ("した", nil)),
            tappedAt: 0,
            sentenceText: "食べました"
        )

        // The surface leads, the lemma follows with its potential unwrap
        // behind it, the joins longest-first, the kanji splits trail —
        // each tagged with its role so the resolution can demote
        // split-only taps to not-found.
        #expect(candidates.map(\.origin) == [
            .tappedSurface, .tappedLemma, .tappedLemma, .join, .join, .split
        ])
    }
}
