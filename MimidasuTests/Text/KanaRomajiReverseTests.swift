import Foundation
@testable import Mimidasu
import Testing

/// The romaji → kana direction the dictionary search queries with: both
/// spellings of the sibilants, sokuon, moraic `n`, the long-vowel ambiguity
/// that cannot be resolved from the letters alone, and the trailing-consonant
/// promise an IME makes (`mak` → まか…まこ).
@Suite("KanaRomaji reverse")
struct KanaRomajiReverseTests {

    // MARK: Syllables

    @Test("converts the plain rows, both directions of the sibilant split")
    func plainRows() {
        #expect(KanaRomaji.convert("makeru")?.kana == "まける")
        #expect(KanaRomaji.convert("akeru")?.kana == "あける")
        #expect(KanaRomaji.convert("syasin")?.kana == "しゃしん")
        #expect(KanaRomaji.convert("shasin")?.kana == "しゃしん")
        #expect(KanaRomaji.convert("tsuki")?.kana == "つき")
        #expect(KanaRomaji.convert("tuki")?.kana == "つき")
        #expect(KanaRomaji.convert("zyaku")?.kana == "じゃく")
        #expect(KanaRomaji.convert("jaku")?.kana == "じゃく")
        #expect(KanaRomaji.convert("tya")?.kana == "ちゃ")
        #expect(KanaRomaji.convert("cha")?.kana == "ちゃ")
        // The foreign and legacy spellings the forward path emits. `kana` is
        // hiragana — the katakana mirror is the caller's candidate, not the
        // converter's claim.
        #expect(KanaRomaji.convert("fasuto")?.kana == "ふぁすと")
        #expect(KanaRomaji.convert("vuxu")?.kana == "ゔゅ")
        #expect(KanaRomaji.convert("shi")?.kana == "し")
        #expect(KanaRomaji.convert("wo")?.kana == "を")
        #expect(KanaRomaji.convert("wi")?.kana == "うぃ")
        #expect(KanaRomaji.convert("ye")?.kana == "いぇ")
        #expect(KanaRomaji.convert("tsa")?.kana == "つぁ")
        #expect(KanaRomaji.convert("kwa")?.kana == "くぁ")
        // The three-mora y-row: ya, yu, and yo each land on their own kana
        // (yoroshiku is the query that caught yo missing from the table).
        #expect(KanaRomaji.convert("yama")?.kana == "やま")
        #expect(KanaRomaji.convert("yuki")?.kana == "ゆき")
        #expect(KanaRomaji.convert("yoji")?.kana == "よじ")
        #expect(KanaRomaji.convert("yoroshiku")?.kana == "よろしく")
        #expect(KanaRomaji.convert("yoroshiku")?.fullyConsumed == true)
    }

    @Test("reads the w-row's wa back, completing the line the extras only borrow")
    func waRow() throws {
        // The forward table emits わ "wa" — the romaji printed under a
        // transcript token (wakaru) must convert back or the search box goes
        // deaf to it. wi/we/wo stay in the extras; わ is the row itself.
        #expect(KanaRomaji.convert("wa")?.kana == "わ")
        let wakaru = try #require(KanaRomaji.convert("wakaru"))
        #expect(wakaru.kana == "わかる")
        #expect(wakaru.fullyConsumed)
        #expect(wakaru.trailingOnset == nil)
        #expect(KanaRomaji.convert("kawa")?.kana == "かわ")
    }

    @Test("folds the case at the boundary, so MAKERU reaches the same rows")
    func foldsCase() throws {
        let conversion = try #require(KanaRomaji.convert("MAKERU"))

        #expect(conversion.kana == "まける")
        #expect(conversion.fullyConsumed)
        #expect(conversion.trailingOnset == nil)
    }

    // MARK: Sokuon

    @Test("geminates a doubled consonant, and the digraph geminates that double nothing")
    func sokuon() {
        #expect(KanaRomaji.convert("kitte")?.kana == "きって")
        #expect(KanaRomaji.convert("sakka")?.kana == "さっか")
        #expect(KanaRomaji.convert("kitte")?.fullyConsumed == true)
        // `tch` and `ssh` geminate without any doubled letter.
        #expect(KanaRomaji.convert("matcha")?.kana == "まっちゃ")
        // `issyo` is いっしょ; the long reading is `issyou`.
        #expect(KanaRomaji.convert("issyo")?.kana == "いっしょ")
        #expect(KanaRomaji.convert("issyou")?.kana == "いっしょう")
    }

    // MARK: Moraic n

    @Test("resolves n by what can follow it")
    func moraicN() {
        #expect(KanaRomaji.convert("man")?.kana == "まん")
        #expect(KanaRomaji.convert("mana")?.kana == "まな")
        #expect(KanaRomaji.convert("manna")?.kana == "まんな")
        #expect(KanaRomaji.convert("man'in")?.kana == "まんいん")
        #expect(KanaRomaji.convert("kanpai")?.kana == "かんぱい")
        #expect(KanaRomaji.convert("hon")?.kana == "ほん")
    }

    // MARK: Long vowels

    @Test("reads the macrons and circumflexes real IMEs accept")
    func macronAndCircumflex() throws {
        let macron = try #require(KanaRomaji.convert("tōkyō"))
        #expect(macron.kana == "とうきょう")
        #expect(macron.variants.contains("とおきょう"))
        let circumflex = try #require(KanaRomaji.convert("tôkyô"))
        #expect(circumflex.kana == "とうきょう")
        let longU = try #require(KanaRomaji.convert("kū"))
        #expect(longU.kana == "くう")
        let longUcircumflex = try #require(KanaRomaji.convert("kû"))
        #expect(longUcircumflex.kana == "くう")
    }

    @Test("keeps both readings of an ambiguous long o, whichever way it is typed")
    func longVowelVariants() throws {
        let wapuro = try #require(KanaRomaji.convert("toukyou"))
        #expect(wapuro.kana == "とうきょう")
        // One rewrite per occurrence: `tookyou` reads both long vowels as お,
        // `toukyoo` only the second one. Neither is knowable from the letters.
        #expect(wapuro.variants == ["とうきょお", "とおきょう"])
        let hepburn = try #require(KanaRomaji.convert("tookyou"))
        #expect(hepburn.kana == "とおきょう")
        #expect(hepburn.variants == ["とうきょう", "とおきょお"])
        // No `o`-row long vowel, so no alternate reading to test.
        let none = try #require(KanaRomaji.convert("man"))
        #expect(none.variants.isEmpty)
        // A spelling carrying both an `oo` and an `ou` offers both rewrites;
        // the ones that resolve to the same kana collapse.
        let both = try #require(KanaRomaji.convert("oou"))
        #expect(Set(both.variants).count == both.variants.count)
        #expect(!both.variants.contains(both.kana))
    }

    // MARK: Partial input

    @Test("stops at an unfinished consonant and names it")
    func trailingOnset() throws {
        let mak = try #require(KanaRomaji.convert("mak"))
        #expect(mak.kana == "ま")
        #expect(mak.fullyConsumed == false)
        #expect(mak.trailingOnset == "k")
        #expect(mak.typedScalarCount == 1)

        let mosh = try #require(KanaRomaji.convert("mosh"))
        #expect(mosh.kana == "も")
        #expect(mosh.trailingOnset == "sh")

        // A doubled consonant at the end is one geminate plus a promise: the
        // scanner consumes the pair as っ and stops on the second letter, which
        // is the onset the expansion then reads.
        let makk = try #require(KanaRomaji.convert("makk"))
        #expect(makk.kana == "まっ")
        #expect(makk.trailingOnset == "k")
        #expect(makk.fullyConsumed == false)
        // The two-letter form of the same promise, for the `onsetExpansions`
        // path a user lands on when they type the cluster out in full.
        #expect(KanaRomaji.onsetExpansions("kk") == ["っか", "っき", "っく", "っけ", "っこ"])

        // `n` and `nn` are complete moras — the scan never leaves them over.
        #expect(KanaRomaji.convert("man")?.fullyConsumed == true)
        #expect(KanaRomaji.convert("makun")?.kana == "まくん")
        #expect(KanaRomaji.convert("makun")?.fullyConsumed == true)
    }

    @Test("drops a trailing character that cannot start a mora, keeping the prefix")
    func invalidTrailingCharacter() throws {
        let max = try #require(KanaRomaji.convert("max"))

        #expect(max.kana == "ま")
        #expect(max.trailingOnset == nil)
        #expect(max.fullyConsumed == false)
    }

    @Test("a leftover that is not a whole onset promises nothing",
          arguments: zip(["best", "test", "ice"], ["べ", "て", "い"]))
    func noTruncatedOnsetPromise(romaji: String, kana: String) throws {
        // The scan still converts what it can — `best` reads べ — but `st` is
        // not an onset, and truncating it to the legal `s` promised さしすせそ
        // to a query that was never romaji. The word is spelled `besuto`, which
        // consumes whole.
        let partial = try #require(KanaRomaji.convert(romaji))

        #expect(partial.kana == kana)
        #expect(partial.fullyConsumed == false)
        #expect(partial.trailingOnset == nil)
    }

    @Test("converts nothing at all when nothing converts")
    func nothingConverts() {
        #expect(KanaRomaji.convert("mk") == nil)
        #expect(KanaRomaji.convert("") == nil)
        #expect(KanaRomaji.convert("x") == nil)
        // An English spelling is not a romaji stem: `sq` and `th` are not
        // onsets, so there is no kana to return and no promise to name.
        #expect(KanaRomaji.convert("squid") == nil)
        #expect(KanaRomaji.convert("th") == nil)
    }

    // MARK: Onset expansions

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
        #expect(KanaRomaji.onsetExpansions("c") == ["か", "き", "く", "け", "こ"])
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

    // MARK: Katakana mirror

    @Test("mirrors the paired hiragana range to katakana")
    func katakanaMirror() {
        #expect(KanaRomaji.katakanaMirror("まける") == "マケル")
        #expect(KanaRomaji.katakanaMirror("ゃ") == "ャ")
        #expect(KanaRomaji.katakanaMirror("ゔ") == "ヴ")
        #expect(KanaRomaji.katakanaMirror("") == "")
    }

    @Test("leaves every scalar outside the paired range untouched")
    func mirrorPassthrough() {
        // 0x309B (゛) and 0x309C (゜) sit *inside* the hiragana block but have no
        // katakana counterpart; a block-wide +0x60 would map them onto ・ (0x30FB)
        // and turn a decomposed か゛ into garbage the dictionary never stores.
        #expect(KanaRomaji.katakanaMirror("か\u{309B}") == "カ\u{309B}")
        #expect(KanaRomaji.katakanaMirror("\u{309C}") == "゜")
        // Kanji passes through; the kana around it is still mirrored — which is
        // why `writingVariants(of:)` only mirrors a pure-kana spelling.
        #expect(KanaRomaji.katakanaMirror("負ける") == "負ケル")
        // The prolonged-sound mark, the middle dot, and Latin pass through.
        #expect(KanaRomaji.katakanaMirror("コー") == "コー")
        #expect(KanaRomaji.katakanaMirror("・") == "・")
        #expect(KanaRomaji.katakanaMirror("a1 ") == "a1 ")
    }
}
