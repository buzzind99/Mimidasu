@testable import Mimidasu
import Testing

// MARK: - Scalar kana/kanji classification

@Suite("Kana classification")
struct KanaClassificationTests {

    @Test("classifies the hiragana block boundaries", arguments: [
        (0x3041, true), // ぁ small a, first hiragana
        (0x3040, false), // just below the block
        (0x309F, true), // ゟ digraph yori, last hiragana
        (0x30A0, false) // just above the block
    ])
    func hiraganaBoundaries(value: UInt32, expected: Bool) throws {
        let scalar = try #require(Unicode.Scalar(value))

        #expect(KanaClassification.isHiragana(scalar) == expected)
    }

    @Test("classifies the katakana block boundaries", arguments: [
        (0x30A0, false), // double hyphen, just below the block
        (0x30A1, true), // ァ small a, first katakana
        (0x30FC, true), // ー long-vowel mark
        (0x30FF, true), // ヿ digraph koto, last katakana
        (0x3100, false) // just above the block
    ])
    func katakanaBoundaries(value: UInt32, expected: Bool) throws {
        let scalar = try #require(Unicode.Scalar(value))

        #expect(KanaClassification.isKatakana(scalar) == expected)
    }

    @Test("classifies kanji, extension planes A–I, compat ideographs, 々, and 〇", arguments: [
        (0x3005, true), // 々 iteration mark
        (0x3006, false), // 〆 ideographic closing mark
        (0x3007, true), // 〇 ideographic zero
        (0x3008, false), // 〈 just above 〇
        (0x3400, true), // 㐂 extension A first
        (0x4DBF, true), // extension A last
        (0x4DC0, false), // ☰ hexagrams, gap between extension A and unified
        (0x4DFF, false), // hexagrams last
        (0x4E00, true), // 一 unified first
        (0x9FFF, true), // unified last
        (0xA000, false), // just above unified
        (0xF8FF, false), // private use, just below the compat block
        (0xF900, true), // 豈, first compatibility ideograph
        (0xFA10, true), // 髙, a Shift-JIS roundtrip compat ideograph
        (0xFAFF, true), // last slot of the compatibility block
        (0xFB00, false), // Latin ligatures, just above the compat block
        (0x20000, true), // 𠀀 extension B first
        (0x20BB7, true), // 𠮷, famously outside the BMP
        (0x2A6DF, true), // extension B last
        (0x2A6E0, false), // gap between extensions B and C
        (0x2A700, true), // extension C first
        (0x2B73F, true), // extension C last
        (0x2B740, true), // extension D first
        (0x2B81F, true), // extension D last
        (0x2B820, true), // extension E first
        (0x2CEAF, true), // extension E last
        (0x2CEB0, true), // extension F first
        (0x2EBEF, true), // extension F last
        (0x2EBF0, true), // extension I first
        (0x2EE5F, true), // extension I last
        (0x2F800, true), // compatibility supplement first
        (0x2FA1F, true), // compatibility supplement last
        (0x2FA20, false), // just above the supplement
        (0x30000, true), // extension G first
        (0x3134A, true), // extension G last
        (0x3134B, false), // gap between extensions G and H
        (0x31350, true), // extension H first
        (0x323AF, true), // extension H last
        (0x323B0, false) // just above extension H
    ])
    func kanjiBoundaries(value: UInt32, expected: Bool) throws {
        let scalar = try #require(Unicode.Scalar(value))

        #expect(KanaClassification.isKanji(scalar) == expected)
    }

    @Test("unites the hiragana and katakana ranges", arguments: [
        (0x3042, true), // あ
        (0x30A2, true), // ア
        (0x30FC, true), // ー
        (0x0041, false), // A
        (0x6F22, false) // 漢
    ])
    func kanaRanges(value: UInt32, expected: Bool) throws {
        let scalar = try #require(Unicode.Scalar(value))

        #expect(KanaClassification.isKana(scalar) == expected)
    }

    @Test("detects kanji anywhere in the text", arguments: [
        ("𠮷野家", true),
        ("𠮷", true),
        ("𠀋", true),
        ("桜", true),
        ("時々", true),
        ("〇〇", true),
        ("髙橋", true), // 髙 is a BMP compat ideograph
        ("かな", false),
        ("ABC", false),
        ("", false)
    ])
    func containsKanji(text: String, expected: Bool) {
        #expect(KanaClassification.containsKanji(text) == expected)
    }

    @Test("detects kana anywhere in the text", arguments: [
        ("こんにちは", true),
        ("カタカナ", true),
        ("ー", true),
        ("かな漢字", true),
        ("漢字", false),
        ("ABC", false),
        ("", false)
    ])
    func containsKana(text: String, expected: Bool) {
        #expect(KanaClassification.containsKana(text) == expected)
    }

    @Test("detects any Japanese script in the text", arguments: [
        ("こんにちは。", true),
        ("今日は良い天気です。", true),
        ("𠮷", true),
        ("𠀋。", true),
        ("カタカナだけ。", true),
        ("髙", true),
        ("2024年", true),
        ("A・B", true), // the middle dot rides along inside the kana block
        ("Is this new?", false),
        ("...", false),
        ("1234", false),
        ("", false)
    ])
    func containsJapanese(text: String, expected: Bool) {
        #expect(KanaClassification.containsJapanese(text) == expected)
    }
}
