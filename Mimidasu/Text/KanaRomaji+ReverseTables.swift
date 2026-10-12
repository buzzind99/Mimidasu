import Foundation

// The syllable, alternate-reading, and onset tables behind `KanaRomaji.convert(_:)`.
// Kept out of the scanner file so both stay under the lint length ceiling; extends
// the same `KanaRomaji` enum.

extension KanaRomaji {
    /// Romaji syllable → hiragana. Greedy longest-match consumes from here,
    /// which is what makes `toukyou` land on とうきょう (と + う) and
    /// `tookyou` on とおきょう (と + お) with no special-casing.
    ///
    /// Only the five vowels have one-character keys — see `scanned(_:)`.
    static let reverseSyllables: [String: String] = {
        // One conjugation row: the consonant (empty for the vowels) plus the
        // vowel sequence and the morae that pair with it.
        struct Row {
            let consonant: String
            let vowels: String
            let morae: String
        }
        var table: [String: String] = [:]
        // Each row spells out its own vowel sequence, because the y-row has
        // three morae (や ゆ よ) — zipping `aiueo` against it would pair them
        // with the wrong vowels and drop `yo` entirely.
        let rows = [
            Row(consonant: "", vowels: "aiueo", morae: "あいうえお"),
            Row(consonant: "k", vowels: "aiueo", morae: "かきくけこ"),
            Row(consonant: "g", vowels: "aiueo", morae: "がぎぐげご"),
            Row(consonant: "s", vowels: "aiueo", morae: "さしすせそ"),
            Row(consonant: "z", vowels: "aiueo", morae: "ざじずぜぞ"),
            Row(consonant: "t", vowels: "aiueo", morae: "たちつてと"),
            Row(consonant: "d", vowels: "aiueo", morae: "だぢづでど"),
            Row(consonant: "n", vowels: "aiueo", morae: "なにぬねの"),
            Row(consonant: "h", vowels: "aiueo", morae: "はひふへほ"),
            Row(consonant: "b", vowels: "aiueo", morae: "ばびぶべぼ"),
            Row(consonant: "p", vowels: "aiueo", morae: "ぱぴぷぺぽ"),
            Row(consonant: "m", vowels: "aiueo", morae: "まみむめも"),
            Row(consonant: "r", vowels: "aiueo", morae: "らりるれろ"),
            Row(consonant: "y", vowels: "auo", morae: "やゆよ"),
            // The w-row is は行 history: modern Japanese carries わ alone,
            // and the forward table spells it "wa" — without this row the
            // romaji the transcript prints (wakaru under 分かる) could never
            // be read back.
            Row(consonant: "w", vowels: "a", morae: "わ")
        ]
        for row in rows {
            for (vowel, kana) in zip(row.vowels, row.morae) {
                table[row.consonant + String(vowel)] = String(kana)
            }
        }
        let extras: [String: String] = [
            // Hepburn alternates for the sibilants.
            "si": "し", "shi": "し", "ti": "ち", "chi": "ち",
            "tu": "つ", "tsu": "つ", "di": "ぢ", "du": "づ",
            "dzu": "づ", "ji": "じ", "zi": "じ", "wo": "を",
            "wu": "う",
            // y-digraphs.
            "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
            "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
            "sha": "しゃ", "shu": "しゅ", "she": "しぇ", "sho": "しょ",
            "sya": "しゃ", "syu": "しゅ", "syo": "しょ",
            "cha": "ちゃ", "chu": "ちゅ", "che": "ちぇ", "cho": "ちょ",
            "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
            "ja": "じゃ", "ju": "じゅ", "je": "じぇ", "jo": "じょ",
            "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
            "zya": "じゃ", "zyu": "じゅ", "zyo": "じょ",
            "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
            "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
            "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
            "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
            "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
            "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
            "dya": "ぢゃ", "dyu": "ぢゅ", "dyo": "ぢょ",
            // Foreign loanword forms.
            "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
            "fya": "ふゃ", "fyu": "ふゅ", "fyo": "ふょ",
            "va": "ゔぁ", "vi": "ゔぃ", "ve": "ゔぇ", "vo": "ゔぉ",
            "vya": "ゔゃ", "vyu": "ゔゅ", "vyo": "ゔょ",
            "wi": "うぃ", "we": "うぇ", "ye": "いぇ",
            // The forward path spells ゔ "vu" (see its table).
            "vu": "ゔ",
            // The forward table above is Hepburn, and ふ round-trips as "fu"
            // (`furoshiki`, not `huroshiki`). "hu" stays for wapuro input; both
            // are one mora either way.
            "fu": "ふ",
            "tsa": "つぁ", "tsi": "つぃ", "tse": "つぇ", "tso": "つぉ",
            "kwa": "くぁ", "kwi": "くぃ", "kwe": "くぇ", "kwo": "くぉ",
            // The c row the Japanese IMEs spell: ca, cu, and co match the k
            // row, but ci and ce read し and せ, not き and け.
            "ca": "か", "ci": "し", "cu": "く", "ce": "せ", "co": "こ",
            // Small kana, the l- and x- prefixes IMEs use for the vowels, plus
            // the small ゃ/ゅ/ょ of the xy- digraphs.
            "la": "ぁ", "li": "ぃ", "lu": "ぅ", "le": "ぇ", "lo": "ぉ",
            "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ",
            "xya": "ゃ", "xyu": "ゅ", "xyo": "ょ"
        ]
        table.merge(extras) { _, extras in extras }
        return table
    }()

    /// The loanword digraph readings the plain table cannot also spell: the
    /// forward path spells ティ/ディ/トゥ/ドゥ/テュ/デュ/ウォ as
    /// `ti/di/tu/du/tyu/dyu/wo`, and those keys already belong to the ち行
    /// and を of wapuro romaji. Replacing the plain values would deafen the
    /// search to wapuro input (`tuki` would never read つき again), so these
    /// ride a second scan into `variants` instead.
    private static let loanwordDigraphs: [String: String] = [
        "ti": "てぃ", "di": "でぃ", "tu": "とぅ", "du": "どぅ",
        "tyu": "てゅ", "dyu": "でゅ", "wo": "うぉ"
    ]

    /// The ぢ/づ family the forward path prints with the じ/ず keys: `ji` and
    /// `zu` spell ぢ and づ, and `ja`/`ju`/`jo` spell the ぢ digraphs. Those
    /// keys already belong to じ and ず in wapuro romaji, so these ride a
    /// second scan into `variants` instead.
    private static let dRowAlternates: [String: String] = [
        "ji": "ぢ", "zu": "づ", "ja": "ぢゃ", "ju": "ぢゅ", "jo": "ぢょ"
    ]

    /// The historical kana the forward path prints: `kwa`, `wi`, and `we`
    /// spell くゎ, ゐ, and ゑ, whose keys the plain table gives to くぁ, うぃ,
    /// and うぇ. A second scan, like the others.
    private static let historicalAlternates: [String: String] = [
        "kwa": "くゎ", "wi": "ゐ", "we": "ゑ"
    ]

    /// The syllable table for each alternate family, each the plain table
    /// with that family merged over it. Only values change — every alternate
    /// key is a plain key of the same length — so every scan consumes exactly
    /// what the plain scan consumes and differs only where a key landed.
    static let alternateSyllableTables: [[String: String]] = [
        reverseSyllables.merging(loanwordDigraphs) { _, alternate in alternate },
        reverseSyllables.merging(dRowAlternates) { _, alternate in alternate },
        reverseSyllables.merging(historicalAlternates) { _, alternate in alternate }
    ]

    /// Consonant cluster → the morae it can begin.
    ///
    /// A plain consonant lists its five row morae (`k` → か…こ) without its
    /// y-digraphs: an IME typing `ka` promises か, and a `ky` promise is its
    /// own cluster. A digraph lists only the digraph morae, because `sh`
    /// means し*ゃ/し*ゅ/し*ぇ/しょ — never a bare し. `c`, `l`, and `x`
    /// list the morae their IME spellings take, which is not always a row:
    /// ci and ce read し and せ, and `l` and `x` promise the small vowel kana
    /// (`xy` the small ゃ/ゅ/ょ).
    static let onsetMorae: [String: [String]] = [
        "k": ["か", "き", "く", "け", "こ"],
        "ky": ["きゃ", "きゅ", "きょ"],
        "g": ["が", "ぎ", "ぐ", "げ", "ご"],
        "gy": ["ぎゃ", "ぎゅ", "ぎょ"],
        "s": ["さ", "し", "す", "せ", "そ"],
        "sh": ["しゃ", "しゅ", "しぇ", "しょ"],
        "z": ["ざ", "じ", "ず", "ぜ", "ぞ"],
        "j": ["じゃ", "じゅ", "じぇ", "じょ"],
        "t": ["た", "ち", "つ", "て", "と"],
        "ch": ["ちゃ", "ちゅ", "ちぇ", "ちょ"],
        "ts": ["つ", "つぁ", "つぃ", "つぇ", "つぉ"],
        "d": ["だ", "ぢ", "づ", "で", "ど"],
        "dy": ["ぢゃ", "ぢゅ", "ぢょ"],
        "n": ["な", "に", "ぬ", "ね", "の"],
        "ny": ["にゃ", "にゅ", "にょ"],
        "h": ["は", "ひ", "ふ", "へ", "ほ"],
        "hy": ["ひゃ", "ひゅ", "ひょ"],
        "f": ["ふ", "ふぁ", "ふぃ", "ふぇ", "ふぉ"],
        "fy": ["ふゃ", "ふゅ", "ふょ"],
        "b": ["ば", "び", "ぶ", "べ", "ぼ"],
        "by": ["びゃ", "びゅ", "びょ"],
        "p": ["ぱ", "ぴ", "ぷ", "ぺ", "ぽ"],
        "py": ["ぴゃ", "ぴゅ", "ぴょ"],
        "m": ["ま", "み", "む", "め", "も"],
        "my": ["みゃ", "みゅ", "みょ"],
        "r": ["ら", "り", "る", "れ", "ろ"],
        "ry": ["りゃ", "りゅ", "りょ"],
        "y": ["や", "ゆ", "よ"],
        // The w-row proper is わ alone; wi/we/wo are extras keys (うぃ, うぇ,
        // を), with ゐ/ゑ as wi/we's historical alternates — so a typed `w`
        // can land any of the four morae below.
        "w": ["わ", "ゐ", "ゑ", "を"],
        "v": ["ゔぁ", "ゔぃ", "ゔぇ", "ゔぉ"],
        "vy": ["ゔゃ", "ゔゅ", "ゔょ"],
        "c": ["か", "し", "く", "せ", "こ"],
        "l": ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ"],
        "x": ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ"],
        "xy": ["ゃ", "ゅ", "ょ"]
    ]
}
