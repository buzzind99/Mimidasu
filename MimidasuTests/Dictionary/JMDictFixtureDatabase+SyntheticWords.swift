import Foundation

// MARK: - Synthetic entries

/// The synthetic entries themselves, split out of the database builder's
/// type body. See `JMDictFixtureDatabase`'s doc comment for what each pins.
extension JMDictFixtureDatabase {
    /// `count` kana-only entries whose readings all begin with `readingPrefix`,
    /// for the tests that need more rows on screen than one page of search
    /// results holds. The readings are gojūon pairs, so every one of them is a
    /// real word shape and all `count` stay unique (up to 46²).
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
                    text: "カタ語", common: false, appliesToKanji: ["*"], jlptLevel: nil,
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
