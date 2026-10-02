import Foundation

/// One rendered run of text plus its optional romaji/kana annotations. The
/// `surface` strings concatenate back to the original text (uncovered spans
/// and runtime failures become plain runs). A run whose romaji equals its
/// surface (Latin, digits, punctuation, kanji without a dictionary reading)
/// is self-transcribed; renderers skip annotating those. `furigana` is only
/// populated for kanji-bearing runs.
final class ReadingSegment {
    var surface: String
    var romaji: String?
    var furigana: String?
    /// The token's dictionary base form (言った → 言う), or nil for
    /// numerals, plain runs, and entry-less tokens — the tap lookup's
    /// fallback query after the surface, catching conjugated forms whose
    /// surface isn't a headword (the furigana reading ranks the hits).
    var lemma: String?
    /// The token's coarse part of speech (名詞, 動詞, …), or nil when the
    /// lexicon row has none.
    var pos: String?

    /// One original token a sokuon-chain merge folded away: its surface
    /// (the inter-token gap rides at the head of an absorbed piece) and
    /// the token's own gap-free kana reading.
    struct MergePiece {
        var surface: String
        var kana: String
    }

    /// The merge seams of a sokuon-chain segment, in order, first seam
    /// first. Set only by the merge path, so the fragmentation pass can
    /// cut at real token boundaries — stem included — when the stem is
    /// unknown and the whole surface gates as entry-less.
    var mergePieces: [MergePiece]?

    init(
        surface: String, romaji: String?, furigana: String? = nil,
        lemma: String? = nil, pos: String? = nil,
        mergePieces: [MergePiece]? = nil
    ) {
        self.surface = surface
        self.romaji = romaji
        self.furigana = furigana
        self.lemma = lemma
        self.pos = pos
        self.mergePieces = mergePieces
    }
}

extension ReadingSegment {
    /// The segment's kana reading as displayed: the furigana when the
    /// annotator aligned one, else the surface itself when it is kana-only
    /// (kana carries its pronunciation by construction). Reading-less kanji,
    /// numerals, and plain runs carry none — a consumer with nothing to
    /// compare should not fold what it was handed.
    var kanaReading: String? {
        if let furigana, !furigana.isEmpty {
            return furigana
        }
        guard !surface.isEmpty,
              surface.unicodeScalars.allSatisfy(KanaClassification.isKana)
        else { return nil }
        return surface
    }
}

/// Produces romaji (wapuro long vowels, Hepburn consonants) and kana
/// furigana for Japanese text from the dictionary tokenizer's per-surface
/// kana readings (`DictionaryEngine`), plus a numeral→counter fusion pass in
/// kana space so Arabic-digit counters read correctly (`600回` →
/// "roppyakkai"). Kanji surfaces the tokenizer lexicon can't read (IPADIC has
/// no standalone entry for 圧, 灼, …) fall back to the prepared JMDict
/// database's reading. The dictionary may still be preparing on first launch;
/// every failure degrades to plain text.
/// Sendable by immutability contract: `cache`, `tokenize`,
/// `readingFallback`, and `headwordGate` are set in init and never mutated
/// afterwards; `NSCache` is internally thread-safe.
final class ReadingAnnotator: @unchecked Sendable {
    /// The process-wide annotator backing the static entry point.
    static let shared = ReadingAnnotator()

    /// The process-wide JMDict database handle behind the reading fallback
    /// and the headword gate — one persistent read-only connection for both
    /// probe paths.
    private static let jmDictLookup = JMDictLookup()

    /// The default reading fallback: a process-wide JMDict lookup consulted
    /// only for kanji surfaces the tokenizer left reading-less — the cached
    /// wrapper below over the raw reading probe.
    private static let jmDictReadingFallback: @Sendable (String) -> String? =
        cachedReadingFallback { surface in
            try jmDictLookup.reading(forWriting: surface)
        }

    /// Wraps a raw reading probe in the per-surface cache: real readings and
    /// genuine misses cache (a miss is its own outcome — names and rare
    /// kanji miss most often and would otherwise re-query every sentence);
    /// a throw answers nil uncached (an infrastructure failure is not a
    /// miss), so the fallback itself re-probes once the database is up.
    /// That guarantee stops at this layer: a render consumed while the probe
    /// threw can still be pinned by the segment cache when no gate probe
    /// flagged it degraded. Injectable probe so tests drive the throw path
    /// without a database.
    static func cachedReadingFallback(
        _ probe: @escaping @Sendable (String) throws -> String?
    ) -> @Sendable (String) -> String? {
        let fallbackCache = ReadingFallbackCache()
        return { surface in
            switch fallbackCache.cachedReading(for: surface) {
            case let .hit(reading): return reading
            case .miss: return nil
            case .notCached: break
            }
            let reading: String?
            do {
                reading = try probe(surface)
            } catch {
                return nil
            }
            fallbackCache.store(reading, for: surface)
            return reading
        }
    }

    /// Sized to hold a full transcription session's finalized sentences
    /// so scroll-back re-renders hit instead of re-tokenizing.
    /// Soft cap only — NSCache still evicts under real memory pressure.
    private let cache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 2000
        return cache
    }()

    /// The default headword gate: a process-wide JMDict lookup answering
    /// whether any headword row (kanji or kana spelling) matches a surface,
    /// memoized per surface. One instance for the process — instantiating
    /// per call would reopen the database on every probe. An infrastructure
    /// failure answers `nil` (degraded: "has entry", never fragment)
    /// without caching, so a still-preparing database re-probes once it is
    /// up — and the degradation flag keeps the degraded render out of the
    /// segment cache, so finalized rows re-probe too.
    private static let jmDictHeadwordGate: @Sendable (String) -> Bool? = memoizedHeadwordGate { surface in
        try jmDictLookup.hasHeadword(surface)
    }

    /// Memoizing wrapper around a raw headword probe. Both real answers
    /// cache — a `false` IS the cached miss, so `NSNumber` needs no
    /// empty-string marker — because garble recurs across the live
    /// partials' 6–10 Hz revisions of the same sentence. A throw answers
    /// `nil` (degraded: callers treat it as "has entry" and must not cache
    /// the render) and is not cached, so a still-preparing database
    /// re-probes once it is up.
    static func memoizedHeadwordGate(
        _ probe: @escaping @Sendable (String) throws -> Bool
    ) -> @Sendable (String) -> Bool? {
        let memo = HeadwordGateMemo()
        return { surface in
            if let cached = memo.answer(for: surface) {
                return cached
            }
            guard let answer = try? probe(surface) else {
                return nil
            }
            memo.store(answer, for: surface)
            return answer
        }
    }

    /// Per-surface memo in front of the headword gate. Larger than the
    /// reading fallback's cache: dictionary-guided prefix cuts multiply the
    /// distinct probe keys a single garbled surface produces. `NSCache` is
    /// internally thread-safe but not marked `Sendable`, so it hides behind
    /// this box.
    private final class HeadwordGateMemo: @unchecked Sendable {
        private let cache = NSCache<NSString, NSNumber>()

        init() {
            cache.countLimit = 1024
        }

        func answer(for surface: String) -> Bool? {
            cache.object(forKey: surface as NSString)?.boolValue
        }

        func store(_ answer: Bool, for surface: String) {
            cache.setObject(NSNumber(value: answer), forKey: surface as NSString)
        }
    }

    /// The token source; injectable so tests drive the annotator without the
    /// dictionary runtime.
    private let tokenize: (String) -> [DictionaryToken]?

    /// The reading source for kanji surfaces the token stream carries no
    /// reading for; injectable so tests drive the fallback without the JMDict
    /// database. Consulted only for kanji-bearing surfaces — kana surfaces
    /// read themselves and read tokens never reach it. Internal for the
    /// fragmentation pass, which renders kanji-bearing fragments through it.
    let readingFallback: @Sendable (String) -> String?

    /// The whole-surface entry gate behind the fragmentation pass: a long
    /// unknown segment the dictionary actually covers stays whole. `nil`
    /// answers "has entry" and flags the pass degraded (the render must
    /// not be cached). Injectable so tests drive fragmentation without the
    /// JMDict database. Receivers must treat input as already NFKC-composed
    /// (the pass probes via `gateText`) — that composition is what lets the
    /// memo's keys dedupe the two kana widths.
    let headwordGate: @Sendable (String) -> Bool?

    init(
        tokenize: @escaping (String) -> [DictionaryToken]? = { text in
            DictionaryEngine.shared.tokenize(text)
        },
        readingFallback: @escaping @Sendable (String) -> String? = ReadingAnnotator.jmDictReadingFallback,
        headwordGate: @escaping @Sendable (String) -> Bool? = ReadingAnnotator.jmDictHeadwordGate
    ) {
        self.tokenize = tokenize
        self.readingFallback = readingFallback
        self.headwordGate = headwordGate
    }

    /// Returns per-run segments for `text` (surface + romaji + furigana), or
    /// `nil` for empty input. Cached — except when the pass ran degraded
    /// (the headword gate's database was unreachable): those whole-or-split
    /// decisions carry no real verdict, so they are not pinned and the next
    /// render re-probes once the dictionary is up.
    static func segments(for text: String) -> [ReadingSegment]? {
        shared.segments(for: text)
    }

    /// Cache-controllable variant. Live partials — growing 6–10 Hz revisions
    /// of the in-flight sentence — pass `caching: false`: every revision is a
    /// distinct string that will never be queried again, so caching them only
    /// churns the store and evicts finalized sentences' entries.
    static func segments(for text: String, caching: Bool) -> [ReadingSegment]? {
        shared.segments(for: text, caching: caching)
    }

    func segments(for text: String, caching: Bool = true) -> [ReadingSegment]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if caching, let cached = cache.object(forKey: trimmed as NSString) as? [ReadingSegment] {
            return cached
        }

        let outcome = transcribe(trimmed)
        // A degraded pass decided whole-or-split without a real verdict;
        // caching would pin those decisions past the dictionary's arrival.
        if caching, !outcome.gateDegraded {
            cache.setObject(outcome.segments as NSArray, forKey: trimmed as NSString)
        }
        return outcome.segments
    }

    // MARK: - Transcription

    private func transcribe(_ text: String) -> (segments: [ReadingSegment], gateDegraded: Bool) {
        guard let raw = tokenize(text) else { return ([], false) }
        let scalars = Array(text.unicodeScalars)
        // A run the tokenizer collapsed into one unknown node hides real word
        // boundaries; re-decoding it in short windows recovers them. Runs ahead
        // of every segment-building rule, so fusion and the fallback
        // fragmentation tier see clean tokens.
        let tokens = Self.repairedTokens(raw, of: text, scalars: scalars, tokenize: tokenize)
        var segments: [ReadingSegment] = []
        var cursor = 0
        // A numeral run held back for counter fusion (一回 → "ikkai").
        var pending: PendingNumber?

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.start > cursor {
                let low = max(0, min(cursor, scalars.count))
                let high = max(low, min(token.start, scalars.count))
                let span = String(String.UnicodeScalarView(scalars[low ..< high]))
                // Whitespace between a held-back number and what follows
                // rides along in the pending run ("2 人" still fuses —
                // ASR output spaces out words); any other uncovered span
                // (三、四本) flushes it, then emits the span as a plain run.
                if pending != nil, span.unicodeScalars.allSatisfy(\.properties.isWhitespace) {
                    pending?.gap = span
                    cursor = token.start
                } else {
                    flush(&pending, into: &segments)
                    appendSpan(from: cursor, to: token.start, of: scalars, into: &segments)
                }
            }
            let surface = Self.scalarSlice(token, of: scalars)
            cursor = token.end

            if Self.isNumeralRun(surface) {
                Self.accumulate(token, surface: surface, into: &pending)
                i += 1
            } else if !fuse(&pending, with: token, surface: surface, into: &segments) {
                if let merged = sokuonMergedSpan(
                    at: i, surface: surface, tokens: tokens, scalars: scalars
                ) {
                    appendToken(
                        DictionaryToken(
                            text: merged.surface,
                            start: token.start,
                            end: tokens[merged.end].end,
                            reading: merged.kana,
                            base: token.base,
                            pos: token.pos
                        ),
                        surface: merged.surface,
                        into: &segments
                    )
                    segments[segments.count - 1].mergePieces = merged.pieces
                    cursor = tokens[merged.end].end
                    i = merged.end + 1
                } else {
                    appendToken(token, surface: surface, into: &segments)
                    i += 1
                }
            } else {
                i += 1
            }
        }
        flush(&pending, into: &segments)
        appendSpan(from: cursor, to: scalars.count, of: scalars, into: &segments)
        return fragmented(segments)
    }

    /// Emits a non-numeral token: the dictionary's surface reading converted
    /// to romaji (with particle and lexical overrides), furigana only for
    /// kanji-bearing surfaces. Kana-only tokens without a dictionary reading
    /// (unknown katakana, stray kana) read themselves by construction; kanji
    /// surfaces without one (IPADIC's standalone-kanji gaps) consult the
    /// JMDict fallback. Tokens that survive both — names, rare ideographs,
    /// punctuation, bare Latin — stay self-transcribed and unannotated.
    private func appendToken(
        _ token: DictionaryToken, surface: String, into segments: inout [ReadingSegment]
    ) {
        var reading = token.reading ?? Self.selfReading(surface)
        if reading == nil, KanaClassification.containsKanji(surface) {
            reading = readingFallback(surface)
        }
        let fields = Self.annotatedFields(surface: surface, reading: reading)
        segments.append(ReadingSegment(
            surface: surface, romaji: fields.romaji, furigana: fields.furigana,
            lemma: token.base, pos: token.pos
        ))
    }

    /// Surface + raw kana reading → final romaji/furigana: the
    /// surfaceReadings → lexicalKana → spokenKana repairs, KanaRomaji
    /// conversion, then the lexicalRomaji/particleRomaji overrides and the
    /// standard kanji furigana rule. A nil reading self-transcribes
    /// (romaji = surface, furigana nil). Shared by all three emitters — the
    /// plain token, the numeral fusion, and the fragmentation pass — so a fused
    /// or split-off segment annotates exactly like a whole token instead of
    /// bare-converting kana.
    ///
    /// `overridingSurface: false` skips the whole-surface table and keeps the
    /// reading it was handed. The fusion's date branch needs that: the calendar
    /// tables give the digit form its date reading (1日 → ついたち) precisely
    /// because the kanji form means the duration word (一日 → いちにち), and
    /// `surfaceReading`'s digit fold maps `1日` onto the `一日` key, where the
    /// override would flip the day back.
    static func annotatedFields(
        surface: String, reading: String?, overridingSurface: Bool = true
    ) -> (romaji: String, furigana: String?) {
        guard var reading else { return (surface, nil) }
        if overridingSurface {
            reading = Self.surfaceReading(surface) ?? reading
        }
        reading = Self.lexicalKana[reading] ?? Self.spokenKana(reading)
        var romaji = KanaRomaji.romaji(fromKana: reading) ?? surface
        if let lexical = Self.lexicalRomaji[reading] {
            romaji = lexical
        } else if let particle = Self.particleRomaji[surface] {
            romaji = particle
        }
        return (romaji, Self.furigana(surface: surface, reading: reading))
    }

    /// Joins a sokuon-bearing token with what follows. IPADIC splits
    /// conjugated forms at the stem boundary (言って → 言っ/て), stranding the
    /// gemination target in the next token's reading; when the pair is
    /// adjacent — or separated only by whitespace, which ASR output inserts
    /// between words (ちゃっ た) — and the next reading begins with a
    /// geminable mora, the two merge into one segment (surface 言って,
    /// reading イッテ) so `KanaRomaji` derives "itte". The merge chains: ASR
    /// spacing can strand several sokuons in a row (なっ ちゃっ てる), so
    /// tokens keep absorbing while the accumulated reading still ends in a
    /// sokuon (なっちゃってる). The intervening `gap` ("" when adjacent) must
    /// be whitespace-only — any other uncovered span blocks the merge — and
    /// folds into the merged surface so it isn't dropped. Overridden
    /// particles (って + は) and numeral runs keep their own conversions; a
    /// genuinely stranded sokuon falls back to the spoken "tsu".
    /// A completed sokuon chain merge: the folded surface, the accumulated
    /// kana, the index of the last absorbed token, and the seam pieces the
    /// surface was assembled from (each with its own gap-free kana).
    private struct SokuonMerge {
        var surface: String
        var kana: String
        var pieces: [ReadingSegment.MergePiece]
        var end: Int
    }

    private func sokuonMergedSpan(
        at index: Int, surface: String,
        tokens: [DictionaryToken], scalars: [Unicode.Scalar]
    ) -> SokuonMerge? {
        guard var kana = tokens[index].reading ?? Self.selfReading(surface),
              kana.unicodeScalars.last.map(Self.isSokuon) == true
        else { return nil }

        var mergedSurface = surface
        var pieces = [ReadingSegment.MergePiece(surface: surface, kana: kana)]
        var end = index
        var previousEnd = tokens[index].end
        while kana.unicodeScalars.last.map(Self.isSokuon) == true, end + 1 < tokens.count {
            let next = tokens[end + 1]
            let nextSurface = Self.scalarSlice(next, of: scalars)
            var gap = ""
            if next.start > previousEnd {
                let low = min(previousEnd, scalars.count)
                let high = min(next.start, scalars.count)
                gap = String(String.UnicodeScalarView(scalars[low ..< high]))
            }
            guard next.start >= previousEnd,
                  gap.unicodeScalars.allSatisfy(\.properties.isWhitespace),
                  let nextReading = next.reading ?? Self.selfReading(nextSurface),
                  !Self.isNumeralRun(nextSurface),
                  Self.particleRomaji[nextSurface] == nil,
                  KanaRomaji.geminates(fromKana: nextReading)
            else { break }
            mergedSurface += gap + nextSurface
            kana += nextReading
            pieces.append(ReadingSegment.MergePiece(
                surface: gap + nextSurface, kana: nextReading
            ))
            end += 1
            previousEnd = next.end
        }
        guard end > index else { return nil }
        return SokuonMerge(surface: mergedSurface, kana: kana, pieces: pieces, end: end)
    }

    private static func isSokuon(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x3063 || scalar.value == 0x30C3 // っ, ッ
    }

    /// A kana-only surface's reading is the surface itself: kana carries its
    /// pronunciation by construction, so unknown katakana and stray kana
    /// still romaji-convert instead of rendering unannotated. Internal for
    /// the fragmentation pass's fragment emitter.
    static func selfReading(_ surface: String) -> String? {
        guard !surface.isEmpty else { return nil }
        return surface.unicodeScalars.allSatisfy(KanaClassification.isKana) ? surface : nil
    }

    /// Furigana for kanji-bearing surfaces: the reading run aligned with the
    /// surface (`ReadingAlignment`) — under IPADIC's per-surface readings
    /// this succeeds for essentially every conjugated token (見た → み walks
    /// 見). Rare quirky readings that don't walk their surface fall back to
    /// the whole-surface reading — shown, never hidden. Kana-only surfaces
    /// need none.
    private static func furigana(surface: String, reading: String) -> String? {
        guard KanaClassification.containsKanji(surface) else { return nil }
        return ReadingAlignment.runs(surface: surface, reading: reading)?
            .map(\.kana).joined() ?? reading
    }

    /// Uncovered spans (the tokenizer should cover everything, but a gap may
    /// appear on engine hiccups) stay plain runs so surfaces concatenate back.
    private func appendSpan(
        from start: Int, to end: Int, of scalars: [Unicode.Scalar],
        into segments: inout [ReadingSegment]
    ) {
        guard start < end else { return }
        let gap = String(String.UnicodeScalarView(scalars[start ..< end]))
        segments.append(ReadingSegment(surface: gap, romaji: gap, furigana: nil))
    }

    // MARK: - Overrides

    enum CachedReading: Equatable {
        case notCached
        case miss
        case hit(String)
    }

    /// Per-surface memo in front of the JMDict reading fallback, sized for
    /// the unknown-kanji vocabulary of a session. `NSCache` is internally
    /// thread-safe but not marked `Sendable`, so it hides behind this box.
    /// Misses are cached as a distinct outcome — names and rare kanji miss
    /// most often and would otherwise re-query every sentence.
    final class ReadingFallbackCache: @unchecked Sendable {
        private let cache = NSCache<NSString, NSString>()

        init() {
            cache.countLimit = 256
        }

        func cachedReading(for surface: String) -> CachedReading {
            guard let hit = cache.object(forKey: surface as NSString) else { return .notCached }
            // An empty string marks a miss; a real reading is never empty
            // (the DB's `reb` is a non-empty kana spelling).
            return hit.length == 0 ? .miss : .hit(hit as String)
        }

        func store(_ reading: String?, for surface: String) {
            cache.setObject(reading as NSString? ?? "", forKey: surface as NSString)
        }
    }

    /// Topic/directional/object particles read by function, not by their
    /// dictionary reading (は → "wa", not "ha").
    private static let particleRomaji = ["は": "wa", "へ": "e", "を": "o"]

    /// Established spellings the kana conversion can't produce: the
    /// greetings' fused particle (は → "ha" mechanically, "wa" by
    /// convention; keyed by reading so the fused kanji forms 今日は and
    /// 今晩は inherit it) and 抹茶's maccha → matcha. The conjunctions
    /// では/それでは/または are single dictionary entries carrying their
    /// etymological は, which is still spoken as the particle "wa" —
    /// segmented で+は contexts reach the bare-particle override instead.
    private static let lexicalRomaji = [
        "こんにちは": "konnichiwa", "こんばんは": "konbanwa", "まっちゃ": "matcha",
        "それでは": "soredewa", "では": "dewa", "または": "matawa"
    ]

    /// Dictionary readings repaired to the spoken form, keyed by the entry's
    /// kana: 入口/入り口 carries the etymological いりくち but is spoken with
    /// rendaku (いりぐち) — keyed by reading so both written forms inherit it.
    private static let lexicalKana = ["いりくち": "いりぐち"]

    /// The lexicon's ニッポン readings repaired to the common にほん: IPADIC
    /// reads 日本 ニッポン and its fused compounds with it (日本人
    /// にっぽんじん, 日本一 にっぽんいち) while splitting the rest (日本中,
    /// 日本製) onto the same にっぽん token — replacing every occurrence
    /// covers both segmentation shapes.
    private static func spokenKana(_ reading: String) -> String {
        reading.contains("にっぽん") ? reading.replacing("にっぽん", with: "にほん") : reading
    }

    // MARK: - Text helpers

    /// Slices the token's scalar span — `start`/`end` are Unicode-scalar
    /// indices into the original input, never `String.Index` values. Internal
    /// for the collapse repair, which re-slices rebased tokens the same way.
    static func scalarSlice(
        _ token: DictionaryToken, of scalars: [Unicode.Scalar]
    ) -> String {
        let low = max(0, min(token.start, scalars.count))
        let high = max(low, min(token.end, scalars.count))
        return String(String.UnicodeScalarView(scalars[low ..< high]))
    }
}
