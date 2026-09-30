import Foundation
@testable import Mimidasu
import Synchronization
import Testing

// MARK: - Fragmentation pass

/// The post-pass that splits long unknown self-transcribed segments (ASR
/// garble bound as one unknown token) into tappable fragments. Canned tokens
/// plus a fake headword gate drive the annotator; every case also pins the
/// concatenation invariant the tap path depends on.
@Suite("ReadingAnnotator fragmentation")
struct ReadingAnnotatorFragmentationTests {

    /// A gate that answers `true` only for the listed headwords.
    private static func gate(_ headwords: String...) -> @Sendable (String) -> Bool? {
        let known = Set(headwords)
        return { surface in known.contains(surface) }
    }

    private func segments(
        _ surfaces: [String], readings: [String?] = [],
        base: String? = nil, pos: String? = nil,
        gate: @escaping @Sendable (String) -> Bool? = { _ in true },
        readingFallback: @escaping @Sendable (String) -> String? = { _ in nil }
    ) throws -> [ReadingSegment] {
        let canned = tokens(surfaces, readings: readings.isEmpty ? [String?](repeating: nil, count: surfaces.count) : readings)
            .map { token in
                DictionaryToken(
                    text: token.text, start: token.start, end: token.end,
                    reading: token.reading, base: base, pos: pos
                )
            }
        let annotator = makeAnnotator(
            canned, readingFallback: readingFallback, headwordGate: gate
        )
        return try #require(annotator.segments(for: surfaces.joined()))
    }

    // MARK: §6 — the observed garble shapes

    @Test("あいいいいいいいい: dictionary lead hit + period-1 tail chunks")
    func dictionaryLeadHitThenPeriodOneTail() throws {
        let segments = try segments(
            ["あいいいいいいいい"], gate: Self.gate("あい")
        )

        #expect(describe(segments) == [
            ["あい", "ai", nil], ["いいい", "iii", nil],
            ["いいい", "iii", nil], ["い", "i", nil]
        ])
        #expect(segments.map(\.surface).joined() == "あいいいいいいいい")
    }

    @Test("モいモいモいもいモい: no period, no hits → balanced cap 5+5")
    func balancedCapFiveFive() throws {
        let segments = try segments(
            ["モいモいモいもいモい"], gate: Self.gate()
        )

        #expect(describe(segments) == [
            ["モいモいモ", "moimoimo", nil], ["いもいモい", "imoimoi", nil]
        ])
        #expect(segments.map(\.surface).joined() == "モいモいモいもいモい")
    }

    @Test("のじゃのじゃのじゃ: repetition period 3 → three segments")
    func repetitionPeriodThree() throws {
        let segments = try segments(
            ["のじゃのじゃのじゃ"], gate: Self.gate()
        )

        #expect(describe(segments) == [
            ["のじゃ", "noja", nil], ["のじゃ", "noja", nil], ["のじゃ", "noja", nil]
        ])
        #expect(segments.map(\.surface).joined() == "のじゃのじゃのじゃ")
    }

    @Test("ソラシナソラシカ: exactly-threshold run still splits 4+4")
    func exactlyThresholdRunSplits() throws {
        let segments = try segments(
            ["ソラシナソラシカ"], gate: Self.gate()
        )

        #expect(describe(segments) == [
            ["ソラシナ", "sorashina", nil], ["ソラシカ", "sorashika", nil]
        ])
        #expect(segments.map(\.surface).joined() == "ソラシナソラシカ")
    }

    @Test("いいいいいいいい: period-1 chunks win over period 2 (3+3+2)")
    func periodOneBeatsPeriodTwo() throws {
        let segments = try segments(
            ["いいいいいいいい"], gate: Self.gate()
        )

        #expect(describe(segments) == [
            ["いいい", "iii", nil], ["いいい", "iii", nil], ["いい", "ii", nil]
        ])
        #expect(segments.map(\.surface).joined() == "いいいいいいいい")
    }

    @Test("ではではではでは: repetition split renders each では as dewa (override chain)")
    func repetitionRenderedThroughOverrideChain() throws {
        let segments = try segments(
            ["ではではではでは"], gate: Self.gate()
        )

        #expect(describe(segments) == [
            ["では", "dewa", nil], ["では", "dewa", nil],
            ["では", "dewa", nil], ["では", "dewa", nil]
        ])
        #expect(segments.map(\.surface).joined() == "ではではではでは")
    }

    @Test("・・・・・・・・: middle dots cut as other → single piece stays whole")
    func middleDotRowStaysWhole() throws {
        let segments = try segments(
            ["・・・・・・・・"], gate: Self.gate()
        )

        #expect(describe(segments) == [["・・・・・・・・", "・・・・・・・・", nil]])
    }

    @Test("the splitter yields a single piece for an other-only run (the guard keeps it whole)")
    func otherOnlyRunSplitsIntoOnePiece() {
        let annotator = makeAnnotator(
            tokens(["・・・・・・・・"], readings: [nil]), headwordGate: { _ in false }
        )

        #expect(annotator.fragments(of: "・・・・・・・・", gate: { _ in false }) == ["・・・・・・・・"])
    }

    @Test("halfwidth punctuation breaks the run as other; the kana sides still fragment")
    func halfwidthPunctuationRunBreaker() throws {
        let segments = try segments(["ｱｱｱｱ､ｱｱｱｱｱｱ"], gate: Self.gate())

        #expect(describe(segments) == [
            ["ｱｱ", "aa", nil], ["ｱｱ", "aa", nil], ["､", "､", nil],
            ["ｱｱｱ", "aaa", nil], ["ｱｱｱ", "aaa", nil]
        ])
        #expect(segments.map(\.surface).joined() == "ｱｱｱｱ､ｱｱｱｱｱｱ")
    }

    // MARK: degraded gate

    @Test("a degraded gate keeps the surface whole and the render uncached, so recovery re-fragments")
    func degradedGateResultIsNotCached() throws {
        // nil = the probe's infrastructure failure (the memo's throw path,
        // unit-tested separately): degraded "has entry".
        let degraded = Mutex(true)
        let annotator = makeAnnotator(
            tokens(["モいモいモいもいモい"], readings: [nil]),
            headwordGate: { _ in
                degraded.withLock { state in state ? nil : false }
            }
        )

        // Degraded pass: "has entry" keeps the garble whole, and the
        // decision is not pinned in the segment cache.
        let first = try #require(annotator.segments(for: "モいモいモいもいモい"))
        #expect(first.map(\.surface) == ["モいモいモいもいモい"])

        // The dictionary arrives: the next render re-probes and fragments.
        degraded.withLock { state in state = false }
        let second = try #require(annotator.segments(for: "モいモいモいもいモい"))
        #expect(second.count >= 2)
        #expect(second.map(\.surface).joined() == "モいモいモいもいモい")
    }

    // MARK: eligibility

    @Test("a JMDict-covered long name stays whole")
    func gateProtectedSurfaceStaysWhole() throws {
        let segments = try segments(
            ["シュワルツェネッガー"], gate: Self.gate("シュワルツェネッガー")
        )

        #expect(describe(segments) == [["シュワルツェネッガー", "shiyuwarutseneggaa", nil]])
    }

    @Test("a known token with a base form is ineligible at the lemma check")
    func knownTokenWithLemmaStaysWhole() throws {
        let segments = try segments(
            ["ダミーダミーダミー"], readings: ["だみー"], base: "ダミー", pos: "名詞", gate: Self.gate()
        )

        #expect(describe(segments) == [["ダミーダミーダミー", "damii", nil]])
        #expect(segments.map(\.lemma) == ["ダミー"])
    }

    @Test("a known token with furigana is ineligible even lemma-less")
    func knownTokenWithFuriganaStaysWhole() throws {
        let segments = try segments(
            ["灼熱灼熱灼熱灼熱"], readings: ["しゃくねつ"], base: "灼熱", gate: Self.gate()
        )

        #expect(describe(segments) == [["灼熱灼熱灼熱灼熱", "shakunetsu", "しゃくねつ"]])
    }

    @Test("an Arabic digit run is skipped before the gate")
    func arabicRunSkipped() throws {
        let consulted = Mutex(false)
        let segments = try segments(
            ["1234567890123"], gate: { _ in
                consulted.withLock { flag in flag = true }
                return false
            }
        )

        #expect(describe(segments) == [["1234567890123", "1234567890123", nil]])
        #expect(!consulted.withLock { flag in flag })
    }

    @Test("kanji numerals are skipped before the gate")
    func kanjiNumeralsSkipped() throws {
        let consulted = Mutex(false)
        let segments = try segments(
            ["一二三四五六七八九十"], gate: { _ in
                consulted.withLock { flag in flag = true }
                return false
            }
        )

        #expect(describe(segments) == [["一二三四五六七八九十", "一二三四五六七八九十", nil]])
        #expect(!consulted.withLock { flag in flag })
    }

    @Test("a punctuation gap span is skipped (no Japanese script)")
    func punctuationGapSpanSkipped() throws {
        let annotator = makeAnnotator(
            [token("あ", start: 0), token("い", start: 9)],
            headwordGate: { _ in false }
        )

        let segments = try #require(annotator.segments(for: "あ、。「」、、、、い"))

        #expect(segments.map(\.surface) == ["あ", "、。「」、、、、", "い"])
        #expect(segments.map(\.surface).joined() == "あ、。「」、、、、い")
    }

    // MARK: cutting mechanics

    @Test("a sub-threshold surface stays whole (7 chars)")
    func belowThresholdStaysWhole() throws {
        let segments = try segments(
            ["あいうえおかき"], gate: Self.gate()
        )

        #expect(describe(segments) == [["あいうえおかき", "aiueokaki", nil]])
    }

    @Test("the dictionary pass emits back-to-back hits and keeps a short tail whole")
    func consecutiveDictionaryHits() throws {
        let segments = try segments(
            ["あいうえおかきくさしすせそたちつてと"],
            gate: Self.gate("あいうえおかきく", "さしすせそたちつ")
        )

        #expect(describe(segments) == [
            ["あいうえおかきく", "aiueokakiku", nil],
            ["さしすせそたちつ", "sashisusesotachitsu", nil],
            ["てと", "teto", nil]
        ])
        #expect(segments.map(\.surface).joined() == "あいうえおかきくさしすせそたちつてと")
    }

    @Test("a mid-length dictionary hit leaves a sub-threshold tail whole")
    func dictionaryHitShortTailStaysWhole() throws {
        let segments = try segments(
            ["あいいいいい" + "いいい"], gate: Self.gate("あいいいいい")
        )

        #expect(describe(segments) == [
            ["あいいいいい", "aiiiii", nil], ["いいい", "iii", nil]
        ])
        #expect(segments.map(\.surface).joined() == "あいいいいい" + "いいい")
    }

    @Test("a non-kana repeated run falls through period-1 to the cap guard")
    func repeatedKanjiTailBelowCapStaysWhole() throws {
        let segments = try segments(
            ["鰭鯛鰭鯛鰭鯛鰭" + "鰭鰭鰭鰭鰭"],
            gate: Self.gate("鰭鯛鰭鯛鰭鯛鰭")
        )

        #expect(describe(segments) == [
            ["鰭鯛鰭鯛鰭鯛鰭", "鰭鯛鰭鯛鰭鯛鰭", nil],
            ["鰭鰭鰭鰭鰭", "鰭鰭鰭鰭鰭", nil]
        ])
    }

    @Test("a period-1 candidate with a stray scalar stays whole below the cap")
    func nearPeriodOneTailStaysWhole() throws {
        let segments = try segments(
            ["あいいいいい" + "いいおいい"], gate: Self.gate("あいいいいい")
        )

        #expect(describe(segments) == [
            ["あいいいいい", "aiiiii", nil], ["いいおいい", "iioii", nil]
        ])
    }

    @Test("kanji repetition splits; a fallback hit annotates, a miss self-transcribes")
    func kanjiRepetitionFallbackHit() throws {
        let segments = try segments(
            ["鰭鰭鰭鰭鰭鰭鰭鰭"],
            gate: Self.gate(),
            readingFallback: { surface in surface == "鰭鰭" ? "ひれ" : nil }
        )

        #expect(describe(segments) == [
            ["鰭鰭", "hire", "ひれ"], ["鰭鰭", "hire", "ひれ"],
            ["鰭鰭", "hire", "ひれ"], ["鰭鰭", "hire", "ひれ"]
        ])
        #expect(segments.map(\.surface).joined() == "鰭鰭鰭鰭鰭鰭鰭鰭")
    }

    @Test("kanji repetition splits with a fallback miss stays self-transcribed")
    func kanjiRepetitionFallbackMiss() throws {
        let segments = try segments(
            ["鰭鯛鰭鯛鰭鯛鰭鯛"], gate: Self.gate()
        )

        #expect(describe(segments) == [
            ["鰭鯛", "鰭鯛", nil], ["鰭鯛", "鰭鯛", nil],
            ["鰭鯛", "鰭鯛", nil], ["鰭鯛", "鰭鯛", nil]
        ])
        #expect(segments.map(\.surface).joined() == "鰭鯛鰭鯛鰭鯛鰭鯛")
    }

    @Test("mixed scripts: an other break yields its own fragment", arguments: [
        "ああああああああA"
    ])
    func otherRunBreaksIntoItsOwnFragment(input: String) throws {
        let segments = try segments([input], gate: Self.gate())

        #expect(describe(segments) == [
            ["あああ", "aaa", nil], ["あああ", "aaa", nil], ["ああ", "aa", nil], ["A", "A", nil]
        ])
        #expect(segments.map(\.surface).joined() == input)
    }

    @Test("49-char prefix-free garble: one failed frontier ends the pass (≤ 7 probes)")
    func prefixFreeGarbleProbesOnce() throws {
        let probes = Mutex(0)
        let garble =
            "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろ"
                + "にんじんじゃ"
        #expect(garble.unicodeScalars.count == 49)
        let segments = try segments([garble], gate: { _ in
            probes.withLock { count in count += 1 }
            return false
        })

        // 1 whole-surface eligibility probe + 7 prefix probes (8…2, one
        // frontier) — the pass never restarts after a failed frontier.
        #expect(probes.withLock { count in count } == 8)
        #expect(segments.count >= 2)
        #expect(segments.allSatisfy { segment in segment.surface.unicodeScalars.count <= Self.threshold })
        #expect(segments.map(\.surface).joined() == garble)
    }

    private static let threshold = ReadingAnnotator.fragmentLengthThreshold

    // MARK: emission fields

    @Test("fragments carry no lemma and the source segment's part of speech")
    func fragmentsCarryPosButNoLemma() throws {
        let segments = try segments(
            ["モいモいモいもいモい"], pos: "名詞", gate: Self.gate()
        )

        #expect(segments.map(\.pos) == ["名詞", "名詞"])
        #expect(segments.map(\.lemma) == [nil, nil])
    }

    @Test("the threshold constant boundary: 7 untouched, 8 split")
    func thresholdBoundary() throws {
        let seven = try segments(["さしすせそたち"], gate: Self.gate())
        let eight = try segments(["さしすせそたちつ"], gate: Self.gate())

        #expect(seven.map(\.surface) == ["さしすせそたち"])
        #expect(eight.map(\.surface) == ["さしすせ", "そたちつ"])
    }

    @Test("fragments of a fragmenting surface always number at least two")
    func eligibleSurfacesYieldAtLeastTwoFragments() throws {
        let surfaces = [
            "あいいいいいいいい", "モいモいモいもいモい", "のじゃのじゃのじゃ",
            "ソラシナソラシカ", "いいいいいいいい", "ではではではでは"
        ]
        for surface in surfaces {
            let annotator = makeAnnotator(
                tokens([surface], readings: [nil]), headwordGate: { _ in false }
            )
            let segments = try #require(annotator.segments(for: surface))

            #expect(
                segments.count >= 2,
                "\(surface) fragmented into \(segments.count) segments"
            )
            #expect(segments.map(\.surface).joined() == surface)
        }
    }
}

// MARK: - Seam-cut merges and halfwidth katakana

/// Sokuon-merged segments fragment at their original token seams when the
/// stem is unknown, and halfwidth katakana flows through eligibility,
/// cutting, rendering, and the gate's folding probe like fullwidth does.
@Suite("ReadingAnnotator fragmentation seams")
struct ReadingAnnotatorSeamFragmentationTests {

    /// A gate that answers `true` only for the listed headwords.
    private static func gate(_ headwords: String...) -> @Sendable (String) -> Bool? {
        let known = Set(headwords)
        return { surface in known.contains(surface) }
    }

    private func segments(
        _ surface: String, gate: @escaping @Sendable (String) -> Bool?
    ) throws -> [ReadingSegment] {
        let annotator = makeAnnotator(tokens([surface], readings: [nil]), headwordGate: gate)
        return try #require(annotator.segments(for: surface))
    }

    // MARK: seam-cut merges

    @Test("an unknown-stem sokuon chain fragments at its merge seams (stem included)")
    func unknownStemMergeSeamFragments() throws {
        let annotator = makeAnnotator(
            tokens(
                ["うっ", "そっ", "かっ", "てる"],
                readings: ["うっ", "そっ", "かっ", "てる"]
            ),
            headwordGate: { _ in false }
        )

        let segments = try #require(annotator.segments(for: "うっそっかってる"))

        #expect(describe(segments) == [
            ["うっ", "utsu", nil], ["そっ", "sotsu", nil],
            ["かっ", "katsu", nil], ["てる", "teru", nil]
        ])
        #expect(segments.map(\.surface).joined() == "うっそっかってる")
    }

    @Test("a merge whose stem carries a base form stays whole despite a miss gate")
    func knownStemMergeStaysWhole() throws {
        let annotator = makeAnnotator(
            [
                token("うっ", start: 0, reading: "うっ", base: "うつ"),
                token("そっ", start: 2, reading: "そっ"),
                token("かっ", start: 4, reading: "かっ"),
                token("てる", start: 6, reading: "てる")
            ],
            headwordGate: { _ in false }
        )

        let segments = try #require(annotator.segments(for: "うっそっかってる"))

        #expect(describe(segments) == [["うっそっかってる", "ussokkatteru", nil]])
        #expect(segments.map(\.lemma) == ["うつ"])
    }

    @Test("a whitespace-gapped chain fragments at its seams, each gap riding the absorbed piece")
    func whitespaceGapSeamFragments() throws {
        let annotator = makeAnnotator(
            spacedTokens(
                ["なっ", "ちゃっ", "てる"],
                readings: ["なっ", "ちゃっ", "てる"]
            ),
            headwordGate: { _ in false }
        )

        let segments = try #require(annotator.segments(for: "なっ ちゃっ てる"))

        #expect(describe(segments) == [
            ["なっ", "natsu", nil], [" ちゃっ", "chatsu", nil], [" てる", "teru", nil]
        ])
        #expect(segments.map(\.surface).joined() == "なっ ちゃっ てる")
    }

    @Test("a freak long absorbed token re-runs the generic splitter at its seam")
    func longSeamPieceReFragments() throws {
        let annotator = makeAnnotator(
            tokens(
                ["うっ", "モいモいモいもい"],
                readings: ["うっ", "モいモいモいもい"]
            ),
            headwordGate: { _ in false }
        )

        let segments = try #require(annotator.segments(for: "うっモいモいモいもい"))

        #expect(describe(segments) == [
            ["うっ", "utsu", nil], ["モいモい", "moimoi", nil], ["モいもい", "moimoi", nil]
        ])
        #expect(segments.map(\.surface).joined() == "うっモいモいモいもい")
    }

    // MARK: halfwidth katakana

    @Test("halfwidth garble fragments like its fullwidth counterpart (repetition halves)")
    func halfwidthGarbleFragments() throws {
        let segments = try segments("ｱｲｳｴｵｱｲｳｴｵ", gate: Self.gate())

        #expect(describe(segments) == [
            ["ｱｲｳｴｵ", "aiueo", nil], ["ｱｲｳｴｵ", "aiueo", nil]
        ])
        #expect(segments.map(\.surface).joined() == "ｱｲｳｴｵｱｲｳｴｵ")
    }

    @Test("a halfwidth name the dictionary covers (by its fullwidth spelling) stays whole")
    func halfwidthGateFoldedStaysWhole() throws {
        let segments = try segments("ﾊﾟｲﾅｯﾌﾟﾙ", gate: Self.gate("パイナップル"))

        #expect(describe(segments) == [["ﾊﾟｲﾅｯﾌﾟﾙ", "painappuru", nil]])
    }
}

// MARK: - Headword gate memo

@Suite("ReadingAnnotator headword gate memo")
struct ReadingAnnotatorHeadwordGateMemoTests {

    @Test("a second call for the same surface does not re-invoke the probe")
    func memoHits() {
        let probes = Mutex(0)
        let gate = ReadingAnnotator.memoizedHeadwordGate { surface in
            probes.withLock { count in count += 1 }
            return surface == "あい"
        }

        #expect(gate("あい") == true)
        #expect(gate("あい") == true)
        #expect(gate("モいモいモいもいモい") == false)
        #expect(gate("モいモいモいもいモい") == false)
        #expect(probes.withLock { count in count } == 2)
    }

    @Test("a throw answers nil (degraded has-entry) without caching, so the next call re-probes")
    func throwAnswersNilUncached() {
        let throwing = Mutex(true)
        let probes = Mutex(0)
        let gate = ReadingAnnotator.memoizedHeadwordGate { _ in
            probes.withLock { count in count += 1 }
            if throwing.withLock({ state in state }) {
                throw JMDictLookupError.databaseMissing
            }
            return false
        }

        // Infrastructure failure: degraded has-entry, and the answer is
        // not cached.
        #expect(gate("ソラシナソラシカ") == nil)
        #expect(gate("ソラシナソラシカ") == nil)
        #expect(probes.withLock { count in count } == 2)

        // Once the database is up, the re-probe caches the real answer.
        throwing.withLock { state in state = false }
        #expect(gate("ソラシナソラシカ") == false)
        #expect(gate("ソラシナソラシカ") == false)
        #expect(probes.withLock { count in count } == 3)
    }
}
