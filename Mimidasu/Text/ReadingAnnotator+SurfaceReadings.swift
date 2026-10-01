import Foundation

// MARK: - Whole-surface reading overrides

/// The reading overrides keyed by the *written form* of a surface, and
/// the key normalization that makes them reachable when the ASR writes
/// the same word differently — spaced out, or in digits where the table
/// is keyed in kanji.
extension ReadingAnnotator {
    /// Whole-surface reading overrides, keyed by the written form: 一日 is a
    /// single dictionary token whose first reading is the date ついたち, but
    /// transcripts mean the duration word いちにち — the date reading stays
    /// with the digit form (1日 → ついたち, `digitDateReadings`). The
    /// standalone 笑 noun reads えみ, but transcripts mean the laughter わら
    /// (net-slang 笑, and ASR fragments like 笑てない that tokenize 笑
    /// standalone). The lexicon's 辺(あたり) entry wins after この, but
    /// あたり is the written 辺り — the bare surface reads へん.
    ///
    /// Also every numeral-prefixed compound the fusion manufactures the wrong
    /// reading for. All three emitters reach this table — the plain token, the
    /// fusion, and the fragmentation pass — so it corrects a fused segment and a
    /// whole token alike. The fusion's `日` branch opts out explicitly via
    /// `annotatedFields(overridingSurface:)`; 年/人 are protected only by no key
    /// happening to match them, so a future 一-prefixed entry would outrank them.
    private static let surfaceReadings = [
        "一日": "いちにち", "笑": "わら", "辺": "へん",
        // Bound-form numerals: the number takes a ひと/ふた/よん stem instead
        // of its cardinal. The tokenizer always splits these into numeral +
        // counter, so mechanical fusion can only ever produce the cardinal
        // form — 二+役 implies にやく, never ふたやく.
        "二役": "ふたやく", "一重": "ひとえ", "八重": "やえ", "五重": "いつえ",
        "七重": "ななえ", "百重": "ももえ", "千重": "ちえ",
        "二手": "ふたて", "一桁": "ひとけた", "二桁": "ふたけた",
        "一揃い": "ひとそろい", "二束": "ふたたば", "四本": "よんほん",
        "一粒": "ひとつぶ", "一房": "ひとふさ", "一組": "ひとくみ",
        "一棟": "ひとむね", "一袋": "ひとふくろ", "一箱": "ひとはこ",
        "二組": "ふたくみ", "二粒": "ふたつぶ", "二晩": "ふたばん",
        "二方": "ふたかた",
        // Lexical numeral stems a bare counter never takes: the し/しち/く
        // readings belong to 月 and 時 alone (`monthReadings`, `hourReadings`)
        // because every other counter wants the cardinal. Widening the rule
        // would break 四分=よんぷん, 七人=ななにん. 六社 is here rather than in
        // `rokuException` because 六者 geminates on the same しゃ reading — see
        // that function's doc.
        "七輪": "しちりん", "六社": "ろくしゃ",
        // The N00 irregularity (さんびゃく/ろっぴゃく/はっぴゃく) is lexical,
        // not phonological — 四百 and 一百 read よんひゃく/いちひゃく though
        // both end in ん — so the measured surfaces are enumerated rather than
        // derived. A kanji numeral resolver would subsume these, the way
        // `digitReadings` already handles the Arabic path. The 間/号 keys are
        // the counter compounds that irregularity propagates into; a counter
        // that follows the hundreds still misses (六百円 = ろくひゃくえん).
        "三百": "さんびゃく", "六百": "ろっぴゃく", "八百": "はっぴゃく",
        "六百間": "ろっぴゃっけん", "六百六号": "ろっぴゃくろくごう"
    ]

    /// The whole-surface override for `surface`, or nil when the table has no
    /// entry. ASR output varies the spacing and the digit width of the same
    /// word, and writes numerals as digits where the table is keyed in kanji —
    /// `二 役`, `１ 桁`, `1桁` — because `accumulate` normalizes digits only for
    /// the digit-run lookup, never for the surface it builds. All three must
    /// fold away or the override is missed by an input-dependent margin, and
    /// the digit form is the likelier one in a real transcript. Lives beside
    /// the table so the token path and the fusion path cannot drift.
    static func surfaceReading(_ surface: String) -> String? {
        let scalars = Array(surface.unicodeScalars.filter { scalar in !scalar.properties.isWhitespace })
        let written = String(String.UnicodeScalarView(scalars))
        if let hit = surfaceReadings[written] {
            return hit
        }
        guard let kanji = foldingLeadingDigit(scalars) else { return nil }
        return surfaceReadings[kanji]
    }

    /// The surface with its leading single digit spelled as a kanji numeral,
    /// or nil when that would be ambiguous: no leading digit, a bare digit,
    /// or a multi-digit run (`600回` resolves through `digitReadings` instead,
    /// and 六百 has no single-digit reading to borrow).
    private static func foldingLeadingDigit(_ scalars: [Unicode.Scalar]) -> String? {
        guard scalars.count > 1, let first = scalars.first,
              let numeral = kanjiNumerals[first], !isDigit(scalars[1])
        else { return nil }
        return String(numeral) + String(String.UnicodeScalarView(scalars.dropFirst()))
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 0xFF10 && scalar.value <= 0xFF19)
    }

    private static let kanjiNumerals: [Unicode.Scalar: Unicode.Scalar] = [
        "1": "一", "2": "二", "3": "三", "4": "四", "5": "五",
        "6": "六", "7": "七", "8": "八", "9": "九",
        "１": "一", "２": "二", "３": "三", "４": "四", "５": "五",
        "６": "六", "７": "七", "８": "八", "９": "九"
    ]
}
