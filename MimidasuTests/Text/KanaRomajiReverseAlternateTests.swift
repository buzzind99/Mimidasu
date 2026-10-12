import Foundation
@testable import Mimidasu
import Testing

/// The alternate readings the letters cannot choose between: the ぢ/づ family under
/// the じ/ず keys, the historical kana, and the loanword reading over every long-o
/// spelling. Each is offered as a variant beside the primary reading.
@Suite("KanaRomaji reverse alternates")
struct KanaRomajiReverseAlternateTests {

    @Test("reads the ぢ/づ family under the じ/ず keys the forward path prints")
    func dRowAlternates() throws {
        // ji and zu are じ and ず in wapuro romaji, so those stay primary and
        // the ぢ/づ reading rides in as a variant.
        let tsuzuku = try #require(KanaRomaji.convert("tsuzuku"))
        #expect(tsuzuku.kana == "つずく")
        #expect(tsuzuku.fullyConsumed)
        #expect(tsuzuku.variants == ["つづく"])
        let hanaji = try #require(KanaRomaji.convert("hanaji"))
        #expect(hanaji.kana == "はなじ")
        #expect(hanaji.fullyConsumed)
        #expect(hanaji.variants == ["はなぢ"])
        #expect(KanaRomaji.convert("tsuzuri")?.variants == ["つづり"])
        // The ぢ digraphs ride ja, ju, and jo beside じゃ, じゅ, and じょ.
        #expect(KanaRomaji.convert("ja")?.variants == ["ぢゃ"])
        #expect(KanaRomaji.convert("ju")?.variants == ["ぢゅ"])
        #expect(KanaRomaji.convert("jo")?.variants == ["ぢょ"])
    }

    @Test("reads back the romaji the forward path prints for each alternate kana",
          arguments: [
              "ぢ", "づ", "ぢゃ", "ぢゅ", "ぢょ", "はなぢ", "ちぢみ",
              // The historical kana, bare and prolonged: the mark cannot stand
              // on a kana the prolonged pass has no vowel for, so ゐ/ゑ/くゎ
              // each need one before ゐー/ゑー/くゎー can read back at all.
              "くゎ", "ゐ", "ゑ", "ゐー", "ゑー", "くゎー"
          ])
    func forwardPrintedRoundTrip(kana: String) throws {
        let romaji = try #require(KanaRomaji.romaji(fromKana: kana))
        let conversion = try #require(KanaRomaji.convert(romaji))
        #expect(conversion.fullyConsumed, "\(romaji)")
        #expect(
            conversion.kana == kana || conversion.variants.contains(kana),
            "\(romaji) reads as \(conversion.kana)"
        )
    }

    @Test("keeps the historical kana the forward path prints as variants")
    func historicalAlternates() {
        #expect(KanaRomaji.convert("kwa")?.kana == "くぁ")
        #expect(KanaRomaji.convert("kwa")?.variants == ["くゎ"])
        #expect(KanaRomaji.convert("wi")?.kana == "うぃ")
        #expect(KanaRomaji.convert("wi")?.variants == ["ゐ"])
        #expect(KanaRomaji.convert("we")?.kana == "うぇ")
        #expect(KanaRomaji.convert("we")?.variants == ["ゑ"])
    }

    @Test("runs the loanword reading over the alternate long-o spelling too")
    func loanwordOverAlternates() throws {
        // kooti's alternate kouti reads こうてぃ, and kouti's alternate kooti
        // reads こおてぃ — the same family the typed spelling gets.
        let kooti = try #require(KanaRomaji.convert("kooti"))
        #expect(kooti.kana == "こおち")
        #expect(kooti.fullyConsumed)
        #expect(kooti.variants.contains("こうてぃ"))
        let kouti = try #require(KanaRomaji.convert("kouti"))
        #expect(kouti.kana == "こうち")
        #expect(kouti.fullyConsumed)
        #expect(kouti.variants.contains("こおてぃ"))
    }

    // MARK: Family invariants

    @Test("the alternate tables only replace values, never keys")
    func alternateKeysArePlainKeys() {
        // convert reports fullyConsumed and the trailing onset from the plain
        // scan alone, so the merge may only swap what a key emits: an
        // alternate key the plain table lacks would consume differently, and
        // the variants would drift from the consumption the conversion
        // reports.
        for table in KanaRomaji.alternateSyllableTables {
            #expect(table.count == KanaRomaji.reverseSyllables.count)
            for key in table.keys {
                #expect(KanaRomaji.reverseSyllables[key] != nil, "\(key)")
            }
        }
    }

    @Test("no family offers the primary reading back as a variant",
          arguments: [
              "ji", "zu", "ja", "ju", "jo",
              "ti", "di", "tu", "du", "tyu", "dyu", "wo",
              "kwa", "wi", "we",
              "kooti", "wookason", "juusu", "chīzu"
          ])
    func variantsExcludePrimary(romaji: String) throws {
        let conversion = try #require(KanaRomaji.convert(romaji))
        #expect(!conversion.variants.contains(conversion.kana), "\(romaji)")
    }

    @Test("the macron spellings ride every alternate family too")
    func macronOverFamilies() throws {
        // tī expands to tii: the loanword family reads てぃい, and the
        // prolonged pass dashes both readings.
        let tii = try #require(KanaRomaji.convert("tī"))
        #expect(tii.kana == "ちい")
        #expect(tii.variants == ["ちー", "てぃい", "てぃー"])

        // jô expands to jou: the d-row family reads the ぢ digraph, and the
        // alternate spelling joo carries every family beside it.
        let jou = try #require(KanaRomaji.convert("jô"))
        #expect(jou.kana == "じょう")
        #expect(jou.variants.contains("ぢょう"))
    }
}
