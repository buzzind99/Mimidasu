import Foundation
@testable import Mimidasu
import Testing

/// The favorite lemma arm against the real tokenizer, end to end: a ない
/// favorite keeps its conjugate surfaces (ねえ, なきゃ, なし, なく, なかろう)
/// dark while spoken ない stays lit, and a self-standing lemma still matches a
/// starred content word.
@Suite("FavoriteWord bound-lemma corpus", .enabled(if: LiveDictionaryRuntime.isAvailable))
struct FavoriteWordBoundLemmaLiveTests {

    private static let annotator = ReadingAnnotator(tokenize: { text in
        LiveDictionaryRuntime.engine?.tokenize(text)
    })

    private static let naiKeys: Set<String> = [FavoriteWord.normalize("ない")]
    private static let miruKeys: Set<String> = [FavoriteWord.normalize("見る")]

    private func litSurfaces(_ text: String, keys: Set<String>) throws -> [String] {
        let segments = try #require(Self.annotator.segments(for: text))
        return segments.filter { segment in
            FavoriteWord.matches(segment, keys: keys, readings: [])
        }
        .map(\.surface)
    }

    @Test("a ない favorite lights only the exact ない surfaces in the debug corpus",
          arguments: [
              "マジ敵際はよくねえ、あいつ絶対座るより手際はいいんだけど。",
              "こっちにつなげなきゃいけないのかこ。",
              "ありがとうございましたお前目の前の逆の退職なしろや！",
              "あ、売らなくてよかったんだなんだ、これで行けたんかよ。",
              "今のだけ見なかったことにして途中まですごくかっこよかったからさせっかくどちらにも悪い話ではなかろう。"
          ])
    func naiConjugatesStayDark(sentence: String) throws {
        let lit = try litSurfaces(sentence, keys: Self.naiKeys)

        #expect(lit.allSatisfy { surface in surface == "ない" }, "unexpectedly lit: \(lit)")
    }

    @Test("a self-standing lemma still matches a starred content word")
    func selfStandingLemmaStillLights() throws {
        let lit = try litSurfaces("今のだけ見なかったことにする", keys: Self.miruKeys)

        #expect(lit.contains("見"))
    }
}
