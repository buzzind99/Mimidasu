import Foundation

// MARK: - Unknown-run collapse repair

extension ReadingAnnotator {

    /// Scalars per re-decode window. A groupable run that outgrows what the
    /// tokenizer's lattice resolves collapses into a single unknown node, and
    /// collapse is a property of the run, not a length threshold — a window
    /// well under the observed collapse length still comes back whole when it
    /// opens mid-word, which is why every attempt is re-decode-and-check rather
    /// than assumed. This cap is chosen to sit under the point where that
    /// starts happening in practice; the windowing reproduced full-sentence
    /// tokenization on every natural sentence tried.
    static let repairWindow = 12

    /// Maximum kana scalars pulled in from the tokens preceding a collapse.
    /// The small kana that opens a collapsed run cannot start a word on its
    /// own, so only its left neighbour makes the real word reachable — enough
    /// for a 4-scalar word plus margin.
    static let repairLeftContext = 8

    /// Scalars that can never begin a Japanese word, so a collapsed run that
    /// opens with one is holding a word boundary the lattice lost rather than
    /// a word it could not find. This is also the pass's name guard: no
    /// Japanese name starts with ゃ/ょ/っ, so a run this pass peels can never
    /// be the dictionary-covered long name the fallback tier's gate protects,
    /// and the gate is not needed to keep it whole.
    ///
    /// The small kana and the geminate, in both widths — nothing else. The set
    /// has to stay inside what the claim above is true of, because the claim is
    /// what licenses running ahead of that gate: `ヴ` and `ゔ` are excluded on
    /// purpose even though they are equally unable to open a *word* on their
    /// own, because `KanaRomaji` reads `ヴァ`/`ゔぁ` as one unit and a bare
    /// `ヴ` converts on its own, so neither can be called word-unstartable. The
    /// middle dot is punctuation, not kana, and needs no listing.
    static let unstartableScalars: Set<Unicode.Scalar> = [
        // Hiragana: the small kana and the geminate.
        "ぁ", "ぃ", "ぅ", "ぇ", "ぉ", "ゃ", "ゅ", "ょ", "ゎ", "ゕ", "ゖ", "っ",
        // Katakana equivalents, plus ヵ/ヶ, which are also unstartable.
        "ァ", "ィ", "ゥ", "ェ", "ォ", "ャ", "ュ", "ョ", "ヮ", "ヵ", "ヶ", "ッ",
        // The halfwidth spellings of the same set, spelled as escapes: the
        // small tsu and the small ke are visually identical, so a literal row
        // would silently carry one of them twice. `KanaClassification` counts
        // `0xFF66...0xFF9F` as kana, so the left-context walk accepts these and
        // the peel has to recognize them too, or it declines for ever on a
        // transcript the walk was willing to reach. Listed rather than reached
        // through an NFKC fold, because folding `ｶﾞ` to `ガ` would change the
        // run's scalar count and every offset derived from it.
        "\u{ff67}", "\u{ff68}", "\u{ff69}", "\u{ff6a}", "\u{ff6b}", "\u{ff6c}",
        "\u{ff6d}", "\u{ff6e}", "\u{ff6f}", "\u{ff9c}"
    ]

    /// Most scalars one peel may set aside. A longer unstartable run is garble
    /// rather than a lost word boundary, and the remainder has to be left with
    /// something to decode.
    static let repairPeelLimit = 2

    /// Rewrites collapsed unknown runs into real word boundaries: the run,
    /// plus kana left context, is re-decoded in short windows and the
    /// result's boundaries are adopted — but only where the re-decode came back
    /// as resolved lexicon rows, so a name the dictionary covers whole reaches
    /// the fallback tier intact instead of being cut here. Deterministic in
    /// `text` plus the tokenizer, so a cached render and a tap-time re-resolve
    /// agree, and no dictionary is consulted.
    ///
    /// Fail-safe throughout — the original tokens survive every rejection, so
    /// the fallback tier fragments them exactly as it did before. The input
    /// array is returned itself when nothing fires, which is the common case:
    /// text without a collapsed run costs no tokenizer calls and no allocation.
    static func repairedTokens(
        _ tokens: [DictionaryToken], of text: String,
        scalars: [Unicode.Scalar]? = nil,
        tokenize: (String) -> [DictionaryToken]?
    ) -> [DictionaryToken] {
        let scalars = scalars ?? Array(text.unicodeScalars)
        // One cheap scan up front: with no collapsed run there is nothing to
        // rebuild, so the input array goes back untouched and unallocated-over.
        guard tokens.contains(where: { token in isCollapsedRun(token, of: scalars) }) else {
            return tokens
        }
        // How many entries each original token contributed to `result`. The
        // left context walked into `result` verbatim on the way here and the
        // re-decode replaces it, which is how a neighbour the tokenizer
        // mis-bound becomes part of the recovered word — so the splice has to
        // drop exactly the entries those original indices produced. A plain
        // `index - first` is that count only while every original token still
        // stands for one entry; an accepted splice breaks the equivalence, and
        // a later splice reaching back into a repaired span then trims the
        // wrong elements and emits scalars twice. Crediting the replacement to
        // the span's last index keeps the accounting exact after any number of
        // prior repairs, in both directions.
        var widths = [Int](repeating: 1, count: tokens.count)
        var result: [DictionaryToken] = []
        var index = 0
        var repaired = false
        var ladder = Ladder(tokens: tokens, scalars: scalars)
        while index < tokens.count {
            guard let repair = repair(at: index, in: ladder, tokenize: tokenize) else {
                result.append(tokens[index])
                index += 1
                continue
            }
            result.removeLast(widths[repair.first ..< index].reduce(0, +))
            result.append(contentsOf: repair.replacement)
            widths.replaceSubrange(
                repair.first ..< repair.end - 1,
                with: repeatElement(0, count: repair.end - 1 - repair.first)
            )
            widths[repair.end - 1] = repair.replacement.count
            index = repair.end
            ladder.repairedThrough = max(ladder.repairedThrough, repair.end - 1)
            repaired = true
        }
        return repaired ? result : tokens
    }

    /// What every rung below `repairedTokens` needs: the original stream, its
    /// text, the tokenizer, and the watermark. One value threaded down instead
    /// of five parameters per rung, and the watermark travels with the rest
    /// rather than being threaded separately.
    private struct Ladder {
        var tokens: [DictionaryToken]
        var scalars: [Unicode.Scalar]
        /// The highest original index an accepted repair has consumed. The
        /// ladder reads the original `tokens`, so a later attempt reaching back
        /// over that line would work from spans this pass has already replaced —
        /// for the peel's fold, re-decoding text an accepted repair had just
        /// proven recoverable and adopting that worse answer in place of it.
        var repairedThrough = -1
    }

    /// One accepted repair: the re-decode that replaces the region's original
    /// tokens, the index the region started at, and the index just past the
    /// collapse token it ended on (a repaired span is never re-examined —
    /// adoption already proved it holds no long unknown).
    private struct Repair {
        var replacement: [DictionaryToken]
        var first: Int
        var end: Int
    }

    /// The first acceptable re-decode for a collapse at `candidate`: the
    /// region alone first, then with one preceding token, then two…, and only
    /// when growing left has failed the one attempt that sets aside a run's
    /// unstartable opening. A candidate at offset 0 offers only the bare
    /// region, and declining every attempt declines the repair.
    private static func repair(
        at candidate: Int, in ladder: Ladder, tokenize: (String) -> [DictionaryToken]?
    ) -> Repair? {
        guard isCollapsedRun(ladder.tokens[candidate], of: ladder.scalars) else { return nil }
        for first in leftContextStarts(before: candidate, in: ladder) {
            guard let replacement = redecoded(
                ladder.tokens[first ... candidate], in: ladder, tokenize: tokenize
            ) else { continue }
            return Repair(replacement: replacement, first: first, end: candidate + 1)
        }
        // Growing left is the better answer when it works — it is what keeps
        // ちょっと one word instead of ょっ plus とまあ… — so the peel only runs
        // on what left context could not reach.
        return peeledRepair(at: candidate, in: ladder, tokenize: tokenize)
    }

    /// A tokenizer unknown node at the fragmentation threshold or wider — a
    /// collapsed run, not the short unreadable name a lone kana or rare
    /// character legitimately produces. The `*` feature row of a grouped
    /// unknown surfaces as a nil reading.
    ///
    /// Only Japanese script, and only script that can *form* a word: a long
    /// Latin or digit run has no word boundaries to recover, and a run of the
    /// script-neutral scalars that ride along inside the katakana block — ・
    /// and the prolonged sound mark ー, which `isKanaRunScalar` counts as kana —
    /// cannot resolve either, since there is no headword to find and no
    /// unstartable opening to peel. Such a run would spend the whole attempt
    /// budget, under the tokenizer's global lock, on every live-partial
    /// revision, to decline.
    private static func isCollapsedRun(
        _ token: DictionaryToken, of scalars: [Unicode.Scalar]
    ) -> Bool {
        guard token.reading == nil,
              token.end - token.start >= fragmentLengthThreshold
        else { return false }
        return scalarSlice(token, of: scalars).unicodeScalars.contains(where: isWordForming)
    }

    /// A scalar that can be part of a Japanese word: kana or kanji, minus the
    /// two script-neutral scalars that sit inside the kana block. Not the same
    /// test as `isKanaRunScalar` — the prolonged sound mark is legitimately
    /// part of a kana run, but a run made of nothing else holds no boundary
    /// worth recovering, so it is not something to re-decode.
    private static func isWordForming(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.value != 0x30FC else { return false } // ー, a sound modifier
        return KanaClassification.isKanji(scalar) || isKanaRunScalar(scalar)
    }

    /// The region starts to try, narrowest first: the collapse token alone,
    /// then one preceding token, then two… Each step may only take an adjacent
    /// kana token carrying no numerals, and the walk stops at the first thing
    /// it cannot take — a script break, a gap, or the budget running out.
    /// Rewriting known neighbours is the point (the `ち` the tokenizer bound
    /// to ちる is what makes ちょっと reachable), and it is safe because a
    /// region always contains the collapse that triggered the walk.
    private static func leftContextStarts(before candidate: Int, in ladder: Ladder) -> [Int] {
        var starts = [candidate]
        var budget = 0
        var first = candidate
        while first > 0 {
            let previous = ladder.tokens[first - 1]
            guard previous.end == ladder.tokens[first].start else { break }
            let surface = scalarSlice(previous, of: ladder.scalars)
            let count = surface.unicodeScalars.count
            guard count > 0, budget + count <= repairLeftContext,
                  !isNumeralRun(surface),
                  surface.unicodeScalars.allSatisfy(Self.isKanaRunScalar)
            else { break }
            budget += count
            first -= 1
            starts.append(first)
        }
        return starts
    }

    /// Whether a scalar can never open a Japanese word.
    private static func isUnstartable(_ scalar: Unicode.Scalar) -> Bool {
        unstartableScalars.contains(scalar)
    }

    /// The last attempt: a run opening with a scalar no word can begin with
    /// is holding a boundary the lattice lost, not a word it could not find,
    /// and no re-decode of the run recovers it — measured across every window
    /// width and every kana left context, all of them collapse again, because
    /// the lattice keeps routing that opening into a grouped unknown node.
    /// Setting it aside and re-decoding what is left whole does work, because
    /// the remainder of a real sentence is a real sentence.
    ///
    /// One undivided call, not a window loop: a window that happens to start
    /// on another unstartable scalar collapses again, so the only clean read
    /// of a peeled remainder is the whole of it. No dictionary is consulted —
    /// the surface that reaches here is unstartable by construction, which is
    /// what keeps this attempt clear of the long names the fallback tier's
    /// gate exists to protect.
    private static func peeledRepair(
        at candidate: Int, in ladder: Ladder, tokenize: (String) -> [DictionaryToken]?
    ) -> Repair? {
        // The re-decode below reuses the declared span verbatim, so it has to
        // be one the text can actually answer for — the same guard `redecoded`
        // makes. Without it a span running past the end of the text, or
        // starting before it, rebases its replacement off an offset
        // `scalarSlice` would have clamped, and the clamped tail is dropped
        // rather than re-covered.
        guard ladder.tokens[candidate].start >= 0,
              ladder.tokens[candidate].end <= ladder.scalars.count
        else { return nil }
        let run = Array(scalarSlice(ladder.tokens[candidate], of: ladder.scalars).unicodeScalars)
        let peeled = run.prefix(while: Self.isUnstartable).prefix(repairPeelLimit)
        guard !peeled.isEmpty, peeled.count < run.count else { return nil }
        let remainder = Array(run.dropFirst(peeled.count))
        guard let decoded = tokenize(scalarString(remainder)), tiles(decoded, of: remainder) else {
            return nil
        }
        let placed = placedPeel(peeled, at: candidate, in: ladder, tokenize: tokenize)
        let offset = ladder.tokens[candidate].start + peeled.count
        return Repair(
            replacement: placed.replacement + decoded.map { token in rebased(token, by: offset) },
            first: placed.first, end: candidate + 1
        )
    }

    /// Where the peeled kana goes. Folding it into the token on its left is
    /// the shape a reader expects — なき + ゃ → なきゃ, "nakya" — and the
    /// tokenizer binds that span itself, so the folded token is re-decoded
    /// rather than assembled by hand. When it cannot be: no left neighbour, a
    /// script break, a gap, a span the lattice will not resolve, or a neighbour
    /// an earlier repair has already replaced. Then the kana stands alone and
    /// the neighbour is left exactly as it was, because a known token is never
    /// downgraded to an unreadable one for nothing — and because folding into a
    /// span this pass already recovered would trade that recovery for a second
    /// guess at the same text.
    private static func placedPeel(
        _ peeled: ArraySlice<Unicode.Scalar>, at candidate: Int, in ladder: Ladder,
        tokenize: (String) -> [DictionaryToken]?
    ) -> (replacement: [DictionaryToken], first: Int) {
        let head = scalarString(peeled)
        // The cheap refusals first: the folded string and its scalars are only
        // worth building for a neighbour that could actually take the kana.
        if candidate > 0, candidate - 1 > ladder.repairedThrough {
            let previous = ladder.tokens[candidate - 1]
            let neighbour = scalarSlice(previous, of: ladder.scalars)
            if previous.end == ladder.tokens[candidate].start,
               !isNumeralRun(neighbour),
               neighbour.unicodeScalars.allSatisfy(Self.isKanaRunScalar)
            {
                let folded = neighbour + head
                if let fold = tokenize(folded), tiles(fold, of: Array(folded.unicodeScalars)) {
                    return (fold.map { token in rebased(token, by: previous.start) }, candidate - 1)
                }
            }
        }
        // Self-read, no lemma: the kana is a fragment of a word the ASR split,
        // and the dictionary has no entry for it on its own. The reading is left
        // nil rather than the surface so this stays a genuinely unresolved row
        // — which is what `appendToken`'s `selfReading` and the fallback tier's
        // `isFragmentable` both read it as — and so the field keeps meaning
        // hiragana, as `DictionaryToken` documents it, on a surface that may be
        // katakana.
        let start = ladder.tokens[candidate].start
        return ([DictionaryToken(
            text: head, start: start, end: start + peeled.count,
            reading: nil, base: nil, pos: nil
        )], candidate)
    }

    /// Re-decodes the region in `repairWindow`-sized windows, rebasing each
    /// window's tokens onto the original text's scalar offsets. An attempt is
    /// only acceptable when every window decodes and each payload tiles its
    /// window exactly — see `tiles` — so no scalar is dropped or misplaced.
    private static func redecoded(
        _ region: ArraySlice<DictionaryToken>, in ladder: Ladder,
        tokenize: (String) -> [DictionaryToken]?
    ) -> [DictionaryToken]? {
        guard let first = region.first?.start, let last = region.last?.end,
              first >= 0, first < last, last <= ladder.scalars.count
        else { return nil }
        let regionScalars = Array(ladder.scalars[first ..< last])
        var decoded: [DictionaryToken] = []
        var cursor = 0
        while cursor < regionScalars.count {
            let high = min(cursor + repairWindow, regionScalars.count)
            let window = Array(regionScalars[cursor ..< high])
            guard let tokens = tokenize(scalarString(window)), tiles(tokens, of: window) else {
                return nil
            }
            decoded.append(contentsOf: tokens.map { token in rebased(token, by: first + cursor) })
            cursor = high
        }
        return decoded
    }

    /// Whether a decoded payload is exactly a tiling of its window: spans
    /// contiguous from 0 and closing on the window's last scalar, every
    /// surface the scalars its own span names, no token still an unknown run at
    /// the fragmentation threshold, and no token the lexicon failed to resolve.
    /// Exact tiling is non-negotiable — `start`/`end` are indices the whole
    /// downstream pipeline re-slices from, and the tap path anchors its join
    /// cursor on the surfaces concatenating back to the sentence, so a short,
    /// padded, or misaligned payload has to be rejected rather than silently
    /// drop or shift scalars.
    ///
    /// The resolved-lemma requirement is what keeps a long name whole. The
    /// repair runs ahead of the fallback tier and never consults its headword
    /// gate, so anything it adopted was already past the point where a
    /// dictionary-covered name could be protected. A payload of *resolved* rows
    /// is real segmentation; a payload that merely re-cut the unknown into
    /// shorter unreadable pieces is the collapse again wearing a different
    /// seam, and is declined so the gate can still answer for the whole
    /// surface.
    private static func tiles(
        _ tokens: [DictionaryToken], of window: [Unicode.Scalar]
    ) -> Bool {
        var cursor = 0
        for token in tokens {
            guard token.start == cursor, token.end > cursor, token.end <= window.count,
                  token.text == scalarString(window[token.start ..< token.end]),
                  token.base != nil, !isLongUnknown(token)
            else { return false }
            cursor = token.end
        }
        return cursor == window.count
    }

    /// Whether a decoded token is still an unknown run at the fragmentation
    /// threshold. Coverage was already checked, so the declared span is the
    /// run's scalar length.
    private static func isLongUnknown(_ token: DictionaryToken) -> Bool {
        token.reading == nil && token.end - token.start >= fragmentLengthThreshold
    }

    /// Window-local offsets back onto the original text: `start`/`end` are
    /// Unicode-scalar indices into it, the `DictionaryToken` contract.
    private static func rebased(_ token: DictionaryToken, by offset: Int) -> DictionaryToken {
        DictionaryToken(
            text: token.text,
            start: token.start + offset,
            end: token.end + offset,
            reading: token.reading,
            base: token.base,
            pos: token.pos,
            bound: token.bound
        )
    }
}
