import Foundation
@testable import Mimidasu
import Testing

// MARK: - Whole-surface reading overrides

/// The numeral-fusion path reaches the shared annotation pipeline, so the
/// whole-surface overrides apply to a fused segment as they always did to a
/// whole token. These pin that reach: every case here reads a surface the
/// fusion manufactures (二役 would be にやく), so they fail outright if the
/// fused segments stop consulting the table — and the guards at the bottom
/// pin the counters the table must leave alone.
@Suite("ReadingAnnotator numeral overrides")
struct ReadingAnnotatorOverridesTests {

    // MARK: - Whole-surface overrides reached from the fusion path

    @Test("reads a bound-form numeral with its stem, not the cardinal the fusion manufactures (二役 → futayaku)",
          arguments: [
              (["二", "役"], ["に", "やく"], "二役", "futayaku", "ふたやく"),
              (["一", "重"], ["いち", "じゅう"], "一重", "hitoe", "ひとえ"),
              (["八", "重"], ["はち", "じゅう"], "八重", "yae", "やえ"),
              (["五", "重"], ["ご", "じゅう"], "五重", "itsue", "いつえ"),
              (["七", "重"], ["なな", "じゅう"], "七重", "nanae", "ななえ"),
              (["百", "重"], ["ひゃく", "じゅう"], "百重", "momoe", "ももえ"),
              (["千", "重"], ["せん", "じゅう"], "千重", "chie", "ちえ"),
              (["二", "手"], ["に", "て"], "二手", "futate", "ふたて"),
              (["一", "桁"], ["いち", "けた"], "一桁", "hitoketa", "ひとけた"),
              (["二", "桁"], ["に", "けた"], "二桁", "futaketa", "ふたけた"),
              (["一", "揃い"], ["いち", "そろい"], "一揃い", "hitosoroi", "ひとそろい"),
              (["二", "束"], ["に", "たば"], "二束", "futataba", "ふたたば"),
              (["四", "本"], ["よん", "ほん"], "四本", "yonhon", "よんほん"),
              (["一", "粒"], ["いち", "つぶ"], "一粒", "hitotsubu", "ひとつぶ"),
              (["一", "房"], ["いち", "ぼう"], "一房", "hitofusa", "ひとふさ"),
              (["一", "組"], ["いち", "くみ"], "一組", "hitokumi", "ひとくみ"),
              (["一", "棟"], ["いち", "むね"], "一棟", "hitomune", "ひとむね"),
              (["一", "袋"], ["いち", "ふくろ"], "一袋", "hitofukuro", "ひとふくろ"),
              (["一", "箱"], ["いち", "はこ"], "一箱", "hitohako", "ひとはこ"),
              (["二", "組"], ["に", "くみ"], "二組", "futakumi", "ふたくみ"),
              (["二", "粒"], ["に", "つぶ"], "二粒", "futatsubu", "ふたつぶ"),
              (["二", "晩"], ["に", "ばん"], "二晩", "futaban", "ふたばん"),
              (["二", "方"], ["に", "ぽう"], "二方", "futakata", "ふたかた")
          ])
    func boundFormNumerals(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("reads the lexical numeral stems no bare counter takes (七輪 → shichirin, 六社 → rokusha)",
          arguments: [
              (["七", "輪"], ["なな", "りん"], "七輪", "shichirin", "しちりん"),
              (["六", "社"], ["ろく", "しゃ"], "六社", "rokusha", "ろくしゃ")
          ])
    func lexicalNumeralStems(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("reads the N00 hundreds, which are lexical rather than phonological (三百 → sanbyaku)",
          arguments: [
              (["三", "百"], ["さん", "ひゃく"], "三百", "sanbyaku", "さんびゃく"),
              (["六", "百"], ["ろく", "ひゃく"], "六百", "roppyaku", "ろっぴゃく"),
              (["八", "百"], ["はち", "ひゃく"], "八百", "happyaku", "はっぴゃく"),
              (["六", "百", "間"], ["ろく", "ひゃく", "けん"], "六百間", "roppyakken", "ろっぴゃっけん"),
              (["六", "百", "六", "号"], ["ろく", "ひゃく", "ろく", "ごう"], "六百六号",
               "roppyakurokugou", "ろっぴゃくろくごう")
          ])
    func n00Hundreds(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    // MARK: - Forced counters and the 六 exception

    @Test("forces the counter reading where the tokenizer gives the noun (一挺 → icchou, not てい)",
          arguments: [
              (["一", "挺"], ["いち", "てい"], "一挺", "icchou", "いっちょう"),
              (["八", "挺"], ["はち", "てい"], "八挺", "hacchou", "はっちょう"),
              (["一", "束"], ["いち", "たば"], "一束", "issoku", "いっそく"),
              (["一", "握"], ["いち", "にぎ"], "一握", "ichiaku", "いちあく")
          ])
    func forcedCounterReading(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("does not geminate 六 before the し-row (六種 → rokushu, not rosshu)",
          arguments: [
              (["六", "種"], ["ろく", "しゅ"], "六種", "rokushu", "ろくしゅ"),
              (["六", "処"], ["ろく", "しょ"], "六処", "rokusho", "ろくしょ"),
              (["六", "尺"], ["ろく", "しゃく"], "六尺", "rokushaku", "ろくしゃく"),
              (["六", "信"], ["ろく", "しん"], "六信", "rokushin", "ろくしん")
          ])
    func rokuShiRow(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("still geminates 六 before しゅう, which the し-row exception must not swallow (六週 → rosshuu)")
    func rokuShuuStillGeminates() throws {
        let annotator = makeAnnotator(tokens(
            ["六", "週"], readings: ["ろく", "しゅう"]
        ))

        let segments = try #require(annotator.segments(for: "六週"))

        #expect(describe(segments) == [["六週", "rosshuu", "ろっしゅう"]])
    }

    /// 六者 shares its しゃ reading with 六社 but does geminate, so it is the
    /// case that keeps `rokuException`'s list from widening to cover しゃ.
    @Test("geminates 六 before 者 on the しゃ reading 六社 is exempt from (六者 → rossha)")
    func rokuShaStillGeminates() throws {
        let annotator = makeAnnotator(tokens(
            ["六", "者"], readings: ["ろく", "しゃ"]
        ))

        let segments = try #require(annotator.segments(for: "六者"))

        #expect(describe(segments) == [["六者", "rossha", "ろっしゃ"]])
    }

    /// 旬's token reading is the noun しゅん; the counter is じゅん. `じ` is not
    /// a geminable onset, so plain fusion already avoids the っ the sh-row
    /// readings needed a carve-out for.
    @Test("forces the counter reading where the tokenizer gives the noun (六旬 → rokujun, not rosshun)")
    func rokuShunCounterReading() throws {
        let annotator = makeAnnotator(tokens(
            ["六", "旬"], readings: ["ろく", "しゅん"]
        ))

        let segments = try #require(annotator.segments(for: "六旬"))

        #expect(describe(segments) == [["六旬", "rokujun", "ろくじゅん"]])
    }

    /// 十重 is deliberately *not* overridden: とえ is JMDict's only reading, but
    /// it is a non-default one and the bound form is rarer than the compounds
    /// じゅうじゅう (十重禁戒) that a key here would break.
    @Test("leaves 重 on the cardinal reading the compounds need (十重 → juujuu, not toe)")
    func juujuuCompoundIntact() throws {
        let annotator = makeAnnotator(tokens(
            ["十", "重"], readings: ["じゅう", "じゅう"]
        ))

        let segments = try #require(annotator.segments(for: "十重"))

        #expect(describe(segments) == [["十重", "juujuu", "じゅうじゅう"]])
    }

    // MARK: - Override lookup key normalization

    @Test("folds the ASR's spacing out of the override lookup (二 役 → futayaku, not にやく)")
    func overrideSurvivesASRSpacing() throws {
        let annotator = makeAnnotator(spacedTokens(
            ["二", "役"], readings: ["に", "やく"]
        ))

        let segments = try #require(annotator.segments(for: "二 役"))

        #expect(describe(segments) == [["二 役", "futayaku", "ふたやく"]])
    }

    @Test("folds the ASR's digit width out of the override lookup (1桁 → hitoketa, not いっけ)")
    func overrideSurvivesDigitWidth() throws {
        let annotator = makeAnnotator(tokens(
            ["1", "桁"], readings: [nil, "けた"]
        ))

        let segments = try #require(annotator.segments(for: "1桁"))

        #expect(describe(segments) == [["1桁", "hitoketa", "ひとけた"]])
    }

    @Test("normalizes a fullwidth digit run behind a gap too (１ 桁 → hitoketa)")
    func fullwidthRunFoldsIntoTheOverrideKey() throws {
        let annotator = makeAnnotator(spacedTokens(
            ["１", "桁"], readings: ["いち", "けた"]
        ))

        let segments = try #require(annotator.segments(for: "１ 桁"))

        #expect(describe(segments) == [["１ 桁", "hitoketa", "ひとけた"]])
    }

    // MARK: - Guards

    @Test("leaves counters the fusion already read correctly untouched (十本/十歳/三回/九日/一人前)",
          arguments: [
              (["十", "本"], ["じゅう", "ほん"], "十本", "juppon", "じゅっぽん"),
              (["十", "歳"], ["じゅう", "さい"], "十歳", "jussai", "じゅっさい"),
              (["三", "回"], ["さん", "かい"], "三回", "sankai", "さんかい"),
              (["九", "日"], ["きゅう", "にち"], "九日", "kokonoka", "ここのか"),
              (["一", "人前"], ["いち", "にんまえ"], "一人前", "ichininmae", "いちにんまえ")
          ])
    func correctCountersUnchanged(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("leaves the readings rejected for a competing sense at the counter (二間 → niken, 一皿 → issara)",
          arguments: [
              (["二", "間"], ["に", "けん"], "二間", "niken", "にけん"),
              (["一", "皿"], ["いち", "さら"], "一皿", "issara", "いっさら")
          ])
    func rejectedSurfacesKeepTheCounterReading(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    @Test("keeps 四百/一百 outside the N00 irregularity (よんひゃく/いちひゃく, not …びゃく)",
          arguments: [
              (["四", "百"], ["よん", "ひゃく"], "四百", "yonhyaku", "よんひゃく"),
              (["一", "百"], ["いち", "ひゃく"], "一百", "ichihyaku", "いちひゃく")
          ])
    func plainHundredsUnchanged(
        surfaces: [String], readings: [String], text: String, romaji: String, furigana: String
    ) throws {
        let annotator = makeAnnotator(tokens(surfaces, readings: readings))

        let segments = try #require(annotator.segments(for: text))

        #expect(describe(segments) == [[text, romaji, furigana]])
    }

    // MARK: - Dataset-divergent single-kanji readings

    /// The lexicon's only bare-改 row reads アラタメ, but the dictionary lists
    /// the writing only under かい — the reading the lookup popup shows. The
    /// override keeps the ruby on the dictionary's side of the disagreement.
    @Test("reads the bare 改 the dictionary's writing implies, not the lexicon's noun row (改 → kai, not aratame)")
    func bareKaiReadsTheDictionaryWriting() throws {
        let annotator = makeAnnotator(tokens(["改"], readings: ["あらため"]))

        let segments = try #require(annotator.segments(for: "改"))

        #expect(describe(segments) == [["改", "kai", "かい"]])
    }

    /// The key is the whole surface, so the word the lexicon's あらため row
    /// actually spells — 改め — keeps its reading.
    @Test("leaves 改め on the reading the lexicon and dictionary agree on (改め → aratame)")
    func aratameWordKeepsItsReading() throws {
        let annotator = makeAnnotator(tokens(["改め"], readings: ["あらため"]))

        let segments = try #require(annotator.segments(for: "改め"))

        #expect(describe(segments) == [["改め", "aratame", "あらため"]])
    }

    /// ASR output spaces words out, and the override is per-segment — the
    /// neighbor's segment and the gap run don't dilute the bare 改's reading.
    @Test("reads a spaced bare 改 through the same override (改 賊 → kai + zoku)")
    func spacedBareKaiReadsTheDictionaryWriting() throws {
        let annotator = makeAnnotator(spacedTokens(
            ["改", "賊"], readings: ["あらため", "ぞく"]
        ))

        let segments = try #require(annotator.segments(for: "改 賊"))

        #expect(describe(segments) == [
            ["改", "kai", "かい"], [" ", " ", nil], ["賊", "zoku", "ぞく"]
        ])
    }
}
