import Foundation
@testable import Mimidasu

// MARK: - Synthetic entries

/// The synthetic entries themselves, split out of the database builder's
/// type body. See `JMDictFixtureDatabase`'s doc comment for what each pins.
extension JMDictFixtureDatabase {
    /// `count` kana-only entries whose readings all begin with `readingPrefix`,
    /// for the tests that need more rows on screen than one page of search
    /// results holds. The readings are gojūon pairs, so every one of them is a
    /// real word shape; they repeat every 46² offsets, so `count` past that
    /// reuses spellings — harmless, because each entry is its own `ent_seq` and
    /// every count in these tests is a count of entries, not of readings.
    ///
    /// `common` cycles every third entry, which is what puts common rows both
    /// inside and outside the first page — a window that only ever showed common
    /// entries would not be exercising the ranking.
    static func bulkWords(
        count: Int, readingPrefix: String, startingAt entSeq: Int
    ) -> [FixtureWord] {
        let gojuon = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん")
        return (0 ..< count).map { offset in
            let reading = readingPrefix
                + String(gojuon[(offset / gojuon.count) % gojuon.count])
                + String(gojuon[offset % gojuon.count])
            return FixtureWord(
                id: String(entSeq + offset),
                kanji: nil,
                kana: [FixtureKana(
                    text: reading, common: offset.isMultiple(of: 3), appliesToKanji: nil,
                    jlptLevel: nil, pitchAccent: nil
                )],
                sense: [FixtureSense(
                    partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil,
                    misc: nil, gloss: [FixtureGloss(lang: "eng", text: "bulk entry \(offset)")]
                )]
            )
        }
    }

    /// `exactCount` entries whose reading **is** `reading`, plus `prefixCount`
    /// whose reading merely starts with it — the shape that makes a skipped
    /// stage mean something offline.
    ///
    /// A window narrower than `exactCount` saturates on the exact tier and never
    /// runs the prefix scan, so the outcome's total is short of the truth and
    /// only a wider window reveals it. The prefix readings are gojuon pairs, so
    /// they stay unique and every one is a real word shape.
    static func bulkWords(
        reading: String, exactCount: Int, prefixCount: Int, startingAt entSeq: Int
    ) -> [FixtureWord] {
        func word(_ text: String, at id: Int) -> FixtureWord {
            FixtureWord(
                id: String(id),
                kanji: nil,
                kana: [FixtureKana(
                    text: text, common: false, appliesToKanji: nil,
                    jlptLevel: nil, pitchAccent: nil
                )],
                sense: [FixtureSense(
                    partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil,
                    misc: nil, gloss: [FixtureGloss(lang: "eng", text: "shared-reading entry \(id)")]
                )]
            )
        }
        let gojuon = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん")
        let exact = (0 ..< exactCount).map { offset in word(reading, at: entSeq + offset) }
        let prefixed = (0 ..< prefixCount).map { offset in
            word(
                reading
                    + String(gojuon[(offset / gojuon.count) % gojuon.count])
                    + String(gojuon[offset % gojuon.count]),
                at: entSeq + exactCount + offset
            )
        }
        return exact + prefixed
    }

    /// `prefixFetchHeadroom + 1` word-range entries whose readings begin with
    /// `readingPrefix` — one row past what the prefix stage's own survivor
    /// bound keeps, the shape in which `matchedCount` is a floor with no stage
    /// having been skipped (the reported `ま` case: a truncated total read as
    /// the whole answer).
    ///
    /// Both suites that need the shape take it from here, because the defect
    /// this replaced was one of them drifting: the paging suite moved its start
    /// below the name boundary and the state suite kept the old one, which
    /// straddled `JMDictNameEntries.ingestOffset` — 8,001 entries from
    /// 9_994_000 put ~2,000 of them in the JMnedict range, where
    /// `filters.admits` classifies them as names and no `.all`-scope count
    /// notices. The start below leaves ~12,000 of headroom under the boundary.
    static func headroomBoundWords(readingPrefix: String = "かん") -> [FixtureWord] {
        bulkWords(
            count: DictionarySearchEngine.prefixFetchHeadroom + 1,
            readingPrefix: readingPrefix,
            startingAt: 9_980_000
        )
    }

    /// `count` name-range entries whose kana readings all begin with
    /// `readingPrefix`, for the filtered-exact-total tests that need a
    /// headroom-bound NAME population. The readings are the same gojūon pairs
    /// `bulkWords` writes, so every one is a real word shape; past 46² offsets
    /// spellings reuse — harmless, because each entry is its own `ent_seq` and
    /// every count here is a count of entries, not of readings.
    ///
    /// Every entry rides at/above `JMDictNameEntries.ingestOffset` with a
    /// `surname` sense, so the `SURNAME` badge filter keeps all of them — the
    /// NAME twin of the word headroom shape, in which a bounded scan would hide
    /// rows the post-join badge filter would have kept and turn the filtered
    /// total into a floor. The kanji writings sit outside the prefix range, so
    /// only the kana rows match; `common` is false throughout because names are
    /// never common, and `jlpt` stays nil because names carry none — mirroring
    /// the 15668306/15668307 fixture entries and the builder's name-ingest
    /// path, which writes plain rows with no JLPT enrichment.
    static func bulkNames(
        count: Int, readingPrefix: String, startingAt entSeq: Int
    ) -> [FixtureWord] {
        let gojuon = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん")
        return (0 ..< count).map { offset in
            let reading = readingPrefix
                + String(gojuon[(offset / gojuon.count) % gojuon.count])
                + String(gojuon[offset % gojuon.count])
            return FixtureWord(
                id: String(entSeq + offset),
                kanji: [FixtureKanji(
                    text: "名\(offset)", common: false, jlptLevel: nil, pitchAccent: nil
                )],
                kana: [FixtureKana(
                    text: reading, common: false, appliesToKanji: nil,
                    jlptLevel: nil, pitchAccent: nil
                )],
                sense: [FixtureSense(
                    partOfSpeech: ["surname"], appliesToKanji: nil, appliesToKana: nil,
                    misc: nil, gloss: [FixtureGloss(lang: "eng", text: "bulk name \(offset)")]
                )]
            )
        }
    }

    /// `prefixFetchHeadroom + 1` name-range entries under `readingPrefix` — one
    /// row past what the prefix stage's own survivor bound keeps, the NAME twin
    /// of `headroomBoundWords`. The start sits safely above
    /// `JMDictNameEntries.ingestOffset` with margin, so no entry straddles the
    /// word/name boundary the way the old shared start did — see that
    /// factory's comment for the straddle this avoids.
    static func headroomBoundNames(readingPrefix: String = "かん") -> [FixtureWord] {
        bulkNames(
            count: DictionarySearchEngine.prefixFetchHeadroom + 1,
            readingPrefix: readingPrefix,
            startingAt: JMDictNameEntries.ingestOffset + 20000
        )
    }

    enum SyntheticWords {
        static let all: [FixtureWord] = [
            FixtureWord(
                id: "9990010",
                kanji: [FixtureKanji(text: "仮語", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "かご", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: ["他語"], appliesToKana: nil,
                        misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "restricted to another writing")]
                    ),
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: [], appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "matches no writing")]
                    ),
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "applies to every writing")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990020",
                kanji: [FixtureKanji(text: "幽語", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "ゆうご", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: ["別語"], appliesToKana: nil,
                        misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "foreign restriction")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990030",
                kanji: [FixtureKanji(text: "雨", common: false, jlptLevel: 5, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "あめ", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "rain")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990040",
                kanji: [FixtureKanji(text: "尾", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "お", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "tail")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990050",
                kanji: [
                    FixtureKanji(text: "先", common: true, jlptLevel: nil, pitchAccent: nil),
                    FixtureKanji(text: "前", common: true, jlptLevel: nil, pitchAccent: nil)
                ],
                kana: [FixtureKana(
                    text: "さき", common: true, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "point; tip; end")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990060",
                kanji: [FixtureKanji(text: "前", common: false, jlptLevel: 5, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "まえ", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "front; before")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990070",
                kanji: [FixtureKanji(text: "叉語", common: true, jlptLevel: nil, pitchAccent: nil)],
                kana: [
                    FixtureKana(text: "さご", common: true, appliesToKanji: ["*"], jlptLevel: nil, pitchAccent: nil),
                    FixtureKana(text: "サゴ", common: true, appliesToKanji: nil, jlptLevel: nil, pitchAccent: nil)
                ],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "kanji-written homophone")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990080",
                kanji: nil,
                kana: [
                    FixtureKana(text: "さご", common: true, appliesToKanji: nil, jlptLevel: nil, pitchAccent: nil),
                    FixtureKana(text: "サゴ", common: true, appliesToKanji: nil, jlptLevel: nil, pitchAccent: nil)
                ],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "kana-written homophone")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990090",
                kanji: [FixtureKanji(text: "呂敷", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "ろしき", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "boundary-crossing split hit")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990100",
                kanji: [FixtureKanji(text: "雨村", common: true, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "あめむら", common: true, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "village rain")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990110",
                kanji: [FixtureKanji(
                    text: "カタ語", common: false, jlptLevel: 2,
                    pitchAccent: FixturePitch(hatsuon: "かた'ご", accPatts: "2", zoPatts: "HH")
                )],
                kana: [FixtureKana(
                    text: "カタ語", common: false, appliesToKanji: ["*"], jlptLevel: 5,
                    pitchAccent: FixturePitch(hatsuon: nil, accPatts: nil, zoPatts: "LL")
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "coincident spelling")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990120",
                kanji: [FixtureKanji(text: "例子", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "れいし", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "uncommon homograph, lower seq")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990130",
                kanji: [FixtureKanji(text: "例子", common: true, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "れいし", common: true, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "common homograph, higher seq")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990140",
                kanji: [FixtureKanji(text: "例子", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "れいし", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "uncommon homograph, higher seq")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990150",
                kanji: nil,
                kana: [FixtureKana(
                    text: "パイナップル", common: true, appliesToKanji: nil, jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "pineapple")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990160",
                kanji: [FixtureKanji(text: "ＴＫＧ", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "ティー・ケー・ジー", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["n"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "tamago kake gohan")]
                    )
                ]
            ),
            FixtureWord(
                id: "9990170",
                kanji: [FixtureKanji(text: "4649", common: true, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "よろしく", common: true, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["int"], appliesToKanji: nil, appliesToKana: nil, misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "best regards; pleased to meet you")]
                    )
                ]
            ),
            FixtureWord(
                id: "15668306",
                kanji: [FixtureKanji(text: "木村", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "きむら", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["place", "surname"], appliesToKanji: nil, appliesToKana: nil,
                        misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "Kimura")]
                    )
                ]
            ),
            FixtureWord(
                id: "15668307",
                kanji: [FixtureKanji(text: "雨村", common: false, jlptLevel: nil, pitchAccent: nil)],
                kana: [FixtureKana(
                    text: "あめむら", common: false, appliesToKanji: ["*"], jlptLevel: nil,
                    pitchAccent: nil
                )],
                sense: [
                    FixtureSense(
                        partOfSpeech: ["surname"], appliesToKanji: nil, appliesToKana: nil,
                        misc: nil,
                        gloss: [FixtureGloss(lang: "eng", text: "Amemura (surname)")]
                    )
                ]
            )
        ]
    }
}
