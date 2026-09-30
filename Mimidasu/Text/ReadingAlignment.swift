import Foundation

/// Aligns a dictionary token's surface with its kana reading: the kana in the
/// surface must match the reading kana-for-kana, in order (katakana folded to
/// hiragana), while kanji chunks freely consume the reading kana between
/// their anchors (見た/みた → 見↔み + た↔た). With IPADIC's per-surface
/// readings this succeeds for essentially every annotated token — the
/// property the tokenizer migration rests on; a nil result marks a reading
/// that doesn't walk its surface.
enum ReadingAlignment {
    /// One aligned chunk: the surface run and the kana reading it. Kanji
    /// chunks may carry an empty kana run when no reading is attributable
    /// to them; kanji all the way to the surface's end come back as one
    /// chunk carrying the whole reading (時々/ときどき).
    struct Run: Equatable {
        let surface: String
        let kana: String
    }

    /// The kana-folded form of `text`: compatibility-normalized (halfwidth
    /// katakana rides the same path as its fullwidth mora), then katakana
    /// folds onto its hiragana counterpart and everything else passes
    /// through. Shared with dictionary lookup ranking so entry readings
    /// compare against furigana text the same way alignment compares surface
    /// kana against reading kana.
    static func foldedKana(_ text: String) -> String {
        String(String.UnicodeScalarView(
            compatibilityComposed(text).unicodeScalars.map(fold)
        ))
    }

    /// The aligned runs, or nil when `reading` doesn't walk `surface`: a
    /// surface kana missing from (or out of order in) the reading, leftover
    /// reading kana, or a non-kana character in the reading. A kanji chunk
    /// tries its anchor kana at each remaining-reading occurrence in order,
    /// backtracking when a choice dead-ends (歌う/うたう — the first う
    /// belongs to the kanji itself, so 歌 must consume うた).
    /// Both sides are compatibility-composed first — halfwidth voiced
    /// kana (ｶﾞ) and the long-vowel mark (ｰ) fold onto their fullwidth
    /// forms — so run surfaces come back in normalized form; consumers read
    /// only the kana side.
    static func runs(surface: String, reading: String) -> [Run]? {
        let surfaceScalars = Array(compatibilityComposed(surface).unicodeScalars)
        let readingScalars = Array(compatibilityComposed(reading).unicodeScalars)
        guard !surfaceScalars.isEmpty, !readingScalars.isEmpty else { return nil }
        guard let chunks = walk(surfaceScalars, from: 0, over: readingScalars[...]) else {
            return nil
        }
        return chunks.map { chunk in Run(surface: chunk.surface, kana: chunk.kana) }
    }

    /// NFKC: the compatibility mapping (halfwidth katakana onto its
    /// fullwidth mora) followed by canonical composition (decomposed
    /// voicing marks onto their precomposed kana). The compatibility
    /// mapping alone decomposes (ｶﾞ → カ + ゛) and never recomposes, so
    /// voiced kana would stay split and unmatchable. Shared with the
    /// annotator's headword gate and romaji conversion, which probe or
    /// convert against text the dictionary stores precomposed.
    static func compatibilityComposed(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .precomposedStringWithCanonicalMapping
    }

    // MARK: - Internals

    /// Walks `surface[index...]` against `reading` and returns the chunks
    /// for the consumed span, or nil. Surface kana match the reading head
    /// one-for-one; each kanji consumes the reading up to an occurrence of
    /// the next surface kana (its anchor) — occurrences are tried left to
    /// right so the remainder's walk can send the choice back here — and a
    /// kanji with no kana after it consumes everything left.
    private static func walk(
        _ surface: [Unicode.Scalar], from index: Int,
        over reading: ArraySlice<Unicode.Scalar>
    ) -> [Chunk]? {
        guard index < surface.count else { return reading.isEmpty ? [] : nil }
        let scalar = surface[index]
        if KanaClassification.isKana(scalar) {
            guard let head = reading.first, fold(head) == fold(scalar),
                  let rest = walk(surface, from: index + 1, over: reading.dropFirst())
            else { return nil }
            return prepend(surface: scalar, kana: [head], matched: true, onto: rest)
        }
        guard KanaClassification.isKanji(scalar) else {
            // Punctuation, Latin, or digits inside a read token: the
            // kana reading can't walk through them.
            return nil
        }
        guard let anchor = surface[(index + 1)...].firstIndex(
            where: KanaClassification.isKana
        ) else {
            // A kanji with no kana after it consumes the whole remaining
            // reading; the trailing surface must be kanji all the way down
            // (学校) — leftover reading kana or a trailing non-kanji scalar
            // (学校。, AB) leaves the walk.
            guard surface[index...].allSatisfy(KanaClassification.isKanji),
                  consumesKanaOnly(reading)
            else { return nil }
            return [Chunk(
                surface: String(String.UnicodeScalarView(surface[index...])),
                kana: String(String.UnicodeScalarView(reading)),
                matched: false
            )]
        }
        let target = fold(surface[anchor])
        var searchStart = reading.startIndex
        while let match = reading[searchStart...].firstIndex(where: { scalar in
            fold(scalar) == target
        }) {
            let consumed = reading[reading.startIndex ..< match]
            if consumesKanaOnly(consumed),
               let rest = walk(surface, from: index + 1, over: reading[match...])
            {
                return prepend(surface: scalar, kana: consumed, matched: false, onto: rest)
            }
            searchStart = reading.index(after: match)
        }
        return nil
    }

    /// A run under construction; `matched` chunks (surface kana mapping to
    /// their own kana) never merge with `consumed` chunks (kanji taking the
    /// reading between anchors), but consecutive same-kind chunks fuse.
    private struct Chunk {
        var surface: String
        var kana: String
        let matched: Bool
    }

    /// Fuses the chunk under construction into the walk result built for
    /// the remainder: the recursion completes right-to-left, so an incoming
    /// same-kind chunk merges into `rest`'s head — matched and consumed
    /// kinds never mix (see `Chunk`).
    private static func prepend(
        surface: Unicode.Scalar, kana: some Sequence<Unicode.Scalar>,
        matched: Bool, onto rest: [Chunk]
    ) -> [Chunk] {
        let kanaString = String(String.UnicodeScalarView(kana))
        var chunks = rest
        if var first = chunks.first, first.matched == matched {
            first.surface = String(surface) + first.surface
            first.kana = kanaString + first.kana
            chunks[0] = first
        } else {
            chunks.insert(
                Chunk(surface: String(surface), kana: kanaString, matched: matched),
                at: 0
            )
        }
        return chunks
    }

    private static func consumesKanaOnly(
        _ scalars: some Collection<Unicode.Scalar>
    ) -> Bool {
        scalars.allSatisfy(KanaClassification.isKana)
    }

    /// Folds katakana onto its hiragana counterpart so katakana surfaces
    /// (ゲーム版) match hiragana readings (げーむばん). Inputs arrive
    /// compatibility-normalized — halfwidth katakana (ｱ, ｶﾞ, ｰ) composed
    /// onto its fullwidth mora before folding — so the block arithmetic
    /// covers every katakana scalar; other non-katakana scalars pass
    /// through unchanged.
    private static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard (0x30A1 ... 0x30F6).contains(scalar.value) else { return scalar }
        return Unicode.Scalar(scalar.value - 0x60)!
    }
}
