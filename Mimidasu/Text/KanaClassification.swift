/// Scalar-level kana/kanji classification shared by the session final gate
/// and sentence buffer, the reading annotator, the surface↔reading
/// alignment, and the dictionary lookup.
enum KanaClassification {
    /// Hiragana and katakana, including the long-vowel mark and small kana.
    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        isHiragana(scalar) || isKatakana(scalar)
    }

    /// Hiragana, including small kana.
    static func isHiragana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041 ... 0x309F).contains(scalar.value)
    }

    /// Katakana, including the long-vowel mark, small kana, and the middle
    /// dot ・ (U+30FB) — script-neutral punctuation that rides along inside
    /// the kana block rather than getting its own case.
    static func isKatakana(_ scalar: Unicode.Scalar) -> Bool {
        (0x30A1 ... 0x30FF).contains(scalar.value)
    }

    /// Kanji, the iteration mark 々, the ideographic zero 〇, the
    /// compatibility ideograph blocks, and the CJK extension planes
    /// (A, B–I).
    static func isKanji(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3005, 0x3007, // 々 iteration mark, 〇 ideographic zero
             0x3400 ... 0x4DBF, // extension A
             0x4E00 ... 0x9FFF, // unified ideographs
             0xF900 ... 0xFAFF, // compatibility ideographs
             0x20000 ... 0x2A6DF, // extension B
             0x2A700 ... 0x2B73F, // extension C
             0x2B740 ... 0x2B81F, // extension D
             0x2B820 ... 0x2CEAF, // extension E
             0x2CEB0 ... 0x2EBEF, // extension F
             0x2EBF0 ... 0x2EE5F, // extension I
             0x2F800 ... 0x2FA1F, // compatibility ideographs supplement
             0x30000 ... 0x3134A, // extension G
             0x31350 ... 0x323AF: // extension H
            true
        default:
            false
        }
    }

    /// Whether `text` contains any kanji (or 々/〇, extension and
    /// compatibility ideographs included).
    static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isKanji)
    }

    /// Whether `text` contains any kana.
    static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isKana)
    }

    /// Whether `text` carries Japanese script — kana or kanji. Kana alone
    /// counts: an ASR final's re-decode often renders kanji words as kana
    /// even when the partial showed kanji. Script-neutral strays inside the
    /// kana blocks (・, the middle dot) count as kana.
    static func containsJapanese(_ text: String) -> Bool {
        containsKana(text) || containsKanji(text)
    }
}
