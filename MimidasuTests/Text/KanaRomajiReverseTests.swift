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
        // Each reading also offers the ー forms its runs hide, so every
        // subset of {と+う→とー, きょ+う→きょー} rides along.
        #expect(wapuro.variants == [
            "とうきょお", "とうきょー", "とおきょう", "とおきょー",
            "とーきょう", "とーきょお", "とーきょー"
        ])
        let hepburn = try #require(KanaRomaji.convert("tookyou"))
        #expect(hepburn.kana == "とおきょう")
        #expect(hepburn.variants == [
            "とうきょう", "とうきょー", "とおきょお", "とおきょー",
            "とーきょう", "とーきょお", "とーきょー"
        ])
        // No `o`-row long vowel, so no alternate reading to test.
        let none = try #require(KanaRomaji.convert("man"))
        #expect(none.variants.isEmpty)
        // A spelling carrying both an `oo` and an `ou` offers both rewrites;
        // the ones that resolve to the same kana collapse.
        let both = try #require(KanaRomaji.convert("oou"))
        #expect(Set(both.variants).count == both.variants.count)
        #expect(!both.variants.contains(both.kana))
    }

    // MARK: Loanword digraphs

    @Test("reads the loanword digraphs whose plain keys belong to wapuro")
    func loanwordDigraphVariants() throws {
        // Each collision: the plain reading stays primary — wapuro input
        // keeps its exact answer — and the loanword reading the forward
        // path also spells rides in as a variant.
        struct Pair {
            let romaji: String
            let plain: String
            let loanword: String
        }
        let pairs = [
            Pair(romaji: "ti", plain: "ち", loanword: "てぃ"),
            Pair(romaji: "di", plain: "ぢ", loanword: "でぃ"),
            Pair(romaji: "tu", plain: "つ", loanword: "とぅ"),
            Pair(romaji: "du", plain: "づ", loanword: "どぅ"),
            Pair(romaji: "tyu", plain: "ちゅ", loanword: "てゅ"),
            Pair(romaji: "dyu", plain: "ぢゅ", loanword: "でゅ"),
            Pair(romaji: "wo", plain: "を", loanword: "うぉ")
        ]
        for pair in pairs {
            let conversion = try #require(KanaRomaji.convert(pair.romaji))
            #expect(conversion.kana == pair.plain, "\(pair.romaji)")
            #expect(conversion.variants == [pair.loanword], "\(pair.romaji)")
        }
    }

    @Test("reaches the loanword spellings the transcript itself prints")
    func loanwordFlagships() throws {
        // The romaji the annotator prints under アイデンティティ must
        // convert back to a reading that mirrors onto it.
        let identity = try #require(KanaRomaji.convert("aidentiti"))
        #expect(identity.kana == "あいでんちち")
        #expect(identity.variants == ["あいでんてぃてぃ"])
        #expect(identity.fullyConsumed)

        let wookason = try #require(KanaRomaji.convert("wookason"))
        // The loanword reading rides in beside the long-vowel alternate the
        // oo↔ou machinery already offered (`wo` + `ou` → をうかそん), and the
        // loanword form's own run hides うぉーかそん (うぉーかそん mirrors to
        // ウォーカソン).
        #expect(wookason.kana == "をおかそん")
        #expect(wookason.variants == ["うぉおかそん", "うぉーかそん", "をうかそん"])
    }

    @Test("keeps the wapuro reading primary where a loanword key lands")
    func wapuroStaysPrimary() {
        #expect(KanaRomaji.convert("tuki")?.kana == "つき")
        #expect(KanaRomaji.convert("tuki")?.variants == ["とぅき"])
        #expect(KanaRomaji.convert("hati")?.kana == "はち")
        #expect(KanaRomaji.convert("hati")?.variants == ["はてぃ"])
        #expect(KanaRomaji.convert("duku")?.kana == "づく")
        #expect(KanaRomaji.convert("duku")?.variants == ["どぅく"])
    }

    @Test("carries the loanword pass through sokuon and moraic n")
    func loanwordScannerInterplay() {
        // The geminate consumes its doubled consonant before the table sees
        // "ti"; `n` resolves to ん before "t", which starts no な行 mora.
        #expect(KanaRomaji.convert("chotti")?.kana == "ちょっち")
        #expect(KanaRomaji.convert("chotti")?.variants == ["ちょってぃ"])
        #expect(KanaRomaji.convert("konti")?.kana == "こんち")
        #expect(KanaRomaji.convert("konti")?.variants == ["こんてぃ"])
        // No loanword key lands, so nothing new is offered.
        #expect(KanaRomaji.convert("makeru")?.variants.isEmpty == true)
    }

    // MARK: Prolonged-sound mark

    @Test("hides the ー readings the forward path spells by repeating a vowel")
    func prolongedSoundVariants() throws {
        // Every subset of the two runs: each mark alone and both together.
        // The primary keeps its wapuro ち reading; the loanword reading rides
        // the variants and offers its own dash forms beside them.
        let paatii = try #require(KanaRomaji.convert("paatii"))
        #expect(paatii.kana == "ぱあちい")
        #expect(paatii.variants == [
            "ぱあちー", "ぱあてぃい", "ぱあてぃー",
            "ぱーちい", "ぱーちー", "ぱーてぃい", "ぱーてぃー"
        ])
        #expect(KanaRomaji.convert("keeki")?.variants == ["けーき"])
        #expect(KanaRomaji.convert("koohii")?.variants.contains("こーひー") == true)
        #expect(KanaRomaji.convert("juusu")?.variants == ["じゅーす"])
        #expect(KanaRomaji.convert("uchiagepaatii")?.variants.contains("うちあげぱーてぃー") == true)
    }

    @Test("rewrites only the successors each mora's mark can stand for")
    func prolongedSuccessorDiscipline() {
        // e takes え and い, o takes お and う; a, i, and u take their own
        // vowel alone.
        #expect(KanaRomaji.prolongedSoundVariants(of: "けい") == ["けー"])
        #expect(KanaRomaji.prolongedSoundVariants(of: "こお") == ["こー"])
        #expect(KanaRomaji.prolongedSoundVariants(of: "こう") == ["こー"])
        #expect(KanaRomaji.prolongedSoundVariants(of: "あい").isEmpty)
        #expect(KanaRomaji.prolongedSoundVariants(of: "ちゅう") == ["ちゅー"])
        // A digraph is one mora: the small kana names its vowel.
        #expect(KanaRomaji.prolongedSoundVariants(of: "きょう") == ["きょー"])
        #expect(KanaRomaji.prolongedSoundVariants(of: "てぃい") == ["てぃー"])
        // っ and ん never prolong.
        #expect(KanaRomaji.prolongedSoundVariants(of: "まんう").isEmpty)
        #expect(KanaRomaji.prolongedSoundVariants(of: "うっう").isEmpty)
        // More than four runs: singles plus the full set only.
        #expect(KanaRomaji.prolongedSoundVariants(of: "おおおおおお").count == 6)
    }

    // MARK: Script-switch probes

    @Test("issues both script directions at every position past the first")
    func scriptSwitchProbes() {
        #expect(KanaRomaji.scriptSwitchProbes(of: "たべる") == ["たベ", "タべ", "たべル", "タベる"])
        // The dash form's probes align with the marked reading: the mark is
        // script-neutral, so the mirrored head carries the ー across.
        #expect(KanaRomaji.scriptSwitchProbes(of: "あぱーとあらし").contains("アパートあ"))
        #expect(KanaRomaji.scriptSwitchProbes(of: "こーひー").contains("コーヒー"))
        // A mixed reading is reached from its own hiragana spelling's form:
        // hiragana head, katakana at the switch.
        #expect(KanaRomaji.scriptSwitchProbes(of: "うべふろんてぃあだいがく").contains("うべフ"))
    }

    @Test("kanji-bearing, katakana, and too-short forms issue nothing")
    func scriptSwitchGuards() {
        // All-katakana readings are already covered by the whole-string
        // mirror; a mixed head matches nothing; one scalar has no position
        // past the first.
        #expect(KanaRomaji.scriptSwitchProbes(of: "アパート").isEmpty)
        #expect(KanaRomaji.scriptSwitchProbes(of: "負ける").isEmpty)
        #expect(KanaRomaji.scriptSwitchProbes(of: "か").isEmpty)
        #expect(KanaRomaji.scriptSwitchProbes(of: "").isEmpty)
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
