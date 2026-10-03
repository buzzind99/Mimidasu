import Foundation
@testable import Mimidasu
import Testing

/// The favorite lemma arm against the real tokenizer, end to end: a ない
/// favorite keeps its conjugate surfaces (ねえ, なきゃ, なし, なく, なかろう)
/// dark while spoken ない stays lit, a self-standing lemma still matches a
/// starred content word, and a context-potential lemma (勝て → 勝てる) lights
/// its starred dictionary form through the unwrap.
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

    /// That the corpus entry still produces the bound ない conjugates the
    /// skip exists for. Without this a dictionary bump that stopped emitting
    /// them would satisfy the dark-listing identically and silently — the
    /// same trap the collapse suite's `expectCollapse` guards.
    private func expectConjugates(_ text: String) throws -> [ReadingSegment] {
        let segments = try #require(Self.annotator.segments(for: text))
        #expect(
            segments.contains { segment in segment.isBound && segment.lemma == "ない" },
            """
            the corpus entry no longer produces ない conjugates — the bound \
            skip is untested here: \(segments.map(\.surface))
            """
        )
        return segments
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
        let segments = try expectConjugates(sentence)
        let lit = segments
            .filter { segment in FavoriteWord.matches(segment, keys: Self.naiKeys, readings: []) }
            .map(\.surface)

        #expect(lit.allSatisfy { surface in surface == "ない" }, "unexpectedly lit: \(lit)")
    }

    @Test("a ない favorite lights the spoken ない")
    func spokenNaiStaysLit() throws {
        let lit = try litSurfaces("行きたくない。", keys: Self.naiKeys)

        #expect(lit == ["ない"])
    }

    @Test("a self-standing lemma still matches a starred content word")
    func selfStandingLemmaStillLights() throws {
        let lit = try litSurfaces("今のだけ見なかったことにする", keys: Self.miruKeys)

        #expect(lit.contains("見"))
    }

    @Test("a 勝つ favorite lights the context-potential 勝て")
    func katsuLightsContextPotentialKate() throws {
        let lit = try litSurfaces(
            "チームに勝て なければ今度こそ", keys: [FavoriteWord.normalize("勝つ")]
        )

        #expect(lit == ["勝て"])
    }

    @Test("a 見る favorite lights 見た, 見ます, and 見ている through their 見 segment",
          arguments: ["見た。", "見ます。", "見ている。"])
    func miruLightsItsSegments(sentence: String) throws {
        let lit = try litSurfaces(sentence, keys: Self.miruKeys)

        #expect(lit == ["見"])
    }
}
