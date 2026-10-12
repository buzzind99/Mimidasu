import Foundation
@testable import Mimidasu
import Testing

/// The onset table's contract, split out of `KanaRomajiReverseTests` (whose type
/// body was within a few lines of the lint ceiling) and kept in the same suite:
/// what a consonant promise is worth is exactly what the syllable tables can
/// read back, so the two halves are pinned together here.
extension KanaRomajiReverseTests {

    @Test("promises a c, l, or x onset the way it promises k")
    func cAndLOnsets() throws {
        let koc = try #require(KanaRomaji.convert("koc"))
        #expect(koc.kana == "こ")
        #expect(koc.fullyConsumed == false)
        #expect(koc.trailingOnset == "c")
        #expect(KanaRomaji.onsetExpansions("c") == ["か", "し", "く", "せ", "こ"])
        #expect(KanaRomaji.onsetExpansions("l") == ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ"])
        // `x` promises the same small vowels as `l`; `xy` the small ゃゅょ.
        #expect(KanaRomaji.onsetExpansions("x") == ["ぁ", "ぃ", "ぅ", "ぇ", "ぉ"])
        #expect(KanaRomaji.onsetExpansions("xy") == ["ゃ", "ゅ", "ょ"])
        let box = try #require(KanaRomaji.convert("box"))
        #expect(box.kana == "ぼ")
        #expect(box.fullyConsumed == false)
        #expect(box.trailingOnset == "x")
        let dol = try #require(KanaRomaji.convert("dol"))
        #expect(dol.kana == "ど")
        #expect(dol.fullyConsumed == false)
        #expect(dol.trailingOnset == "l")
        // A lone consonant converts nothing, c and l included.
        #expect(KanaRomaji.convert("c") == nil)
        #expect(KanaRomaji.convert("l") == nil)
    }

    @Test("promises the w row's historical morae and the ゔ y-digraph")
    func wAndVYOnsets() throws {
        // `w` was already a promise, but it answered わ alone: wi, we and wo
        // are real keys — the kana the forward path prints under them — so the
        // typed onset can land any of the four.
        #expect(KanaRomaji.onsetExpansions("w") == ["わ", "ゐ", "ゑ", "を"])
        // `vy` promised nothing at all, although vya/vyu/vyo are keys the
        // forward path prints (ゔゅ → "vyu"), so typing `vy` dropped morae it
        // could name — the same gap the c/l/x rows had.
        #expect(KanaRomaji.onsetExpansions("vy") == ["ゔゃ", "ゔゅ", "ゔょ"])
        let kovy = try #require(KanaRomaji.convert("kovy"))
        #expect(kovy.kana == "こ")
        #expect(kovy.fullyConsumed == false)
        #expect(kovy.trailingOnset == "vy")
    }

    @Test("expands a plain consonant into its row's five morae")
    func plainOnsetExpansions() {
        #expect(KanaRomaji.onsetExpansions("k") == ["か", "き", "く", "け", "こ"])
        #expect(KanaRomaji.onsetExpansions("s") == ["さ", "し", "す", "せ", "そ"])
        #expect(KanaRomaji.onsetExpansions("n") == ["な", "に", "ぬ", "ね", "の"])
        #expect(KanaRomaji.onsetExpansions("t") == ["た", "ち", "つ", "て", "と"])
        #expect(KanaRomaji.onsetExpansions("y") == ["や", "ゆ", "よ"])
        // Case folds, like the rest of the converter.
        #expect(KanaRomaji.onsetExpansions("K") == ["か", "き", "く", "け", "こ"])
    }

    @Test("expands a digraph onset into its digraph set, never the bare kana")
    func digraphOnsetExpansions() {
        #expect(KanaRomaji.onsetExpansions("sh") == ["しゃ", "しゅ", "しぇ", "しょ"])
        #expect(KanaRomaji.onsetExpansions("ch") == ["ちゃ", "ちゅ", "ちぇ", "ちょ"])
        #expect(KanaRomaji.onsetExpansions("j") == ["じゃ", "じゅ", "じぇ", "じょ"])
        #expect(KanaRomaji.onsetExpansions("ky") == ["きゃ", "きゅ", "きょ"])
        #expect(KanaRomaji.onsetExpansions("ts") == ["つ", "つぁ", "つぃ", "つぇ", "つぉ"])
    }

    @Test("carries the sokuon through a geminating expansion")
    func sokuonOnsetExpansions() {
        #expect(KanaRomaji.onsetExpansions("kk") == ["っか", "っき", "っく", "っけ", "っこ"])
        #expect(KanaRomaji.onsetExpansions("tch") == ["っちゃ", "っちゅ", "っちぇ", "っちょ"])
        #expect(KanaRomaji.onsetExpansions("ssh") == ["っしゃ", "っしゅ", "っしぇ", "っしょ"])
        // `nn` is moraic, not a geminate.
        #expect(KanaRomaji.onsetExpansions("nn") == [])
        // Neither is an unknown cluster, an empty onset, or a lone consonant.
        #expect(KanaRomaji.onsetExpansions("n").first == "な")
        #expect(KanaRomaji.onsetExpansions("") == [])
        #expect(KanaRomaji.onsetExpansions("q") == [])
    }
}
