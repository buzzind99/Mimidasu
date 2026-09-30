import Foundation

// MARK: - Unknown-segment fragmentation

extension ReadingAnnotator {

    /// Flat surface length at and above which an entry-less self-transcribed
    /// segment becomes a fragmentation candidate. Catches the repeated-vocable
    /// garble ASR emits for uncaptured audio, which binds as one long unknown
    /// token and is otherwise untappable.
    static let fragmentLengthThreshold = 8

    /// Post-pass over finished segments: long unknown runs (ASR garble the
    /// tokenizer bound as one unknown token, gap spans, sokuon chains whose
    /// first token is unknown) split into tappable fragments. Known tokens —
    /// anything carrying a lemma or furigana — and surfaces the dictionary
    /// covers whole are never touched, so surfaces keep concatenating back.
    /// Decisions are stable per text for as long as the dictionary state is
    /// (cached segments return verbatim); a tap that re-resolves after the
    /// dictionary state flipped keeps its tap-time snapshot authoritative,
    /// and a resulting index skew fails closed through the expansion's
    /// bounds guard. Returns the pass's segments plus whether any gate
    /// probe failed on infrastructure (answered "has entry" without a real
    /// verdict): a degraded pass's decisions may flip once the dictionary
    /// is up, so callers must not cache them.
    func fragmented(_ segments: [ReadingSegment]) -> (segments: [ReadingSegment], gateDegraded: Bool) {
        var gateDegraded = false
        /// The pass's probe: NFKC-composed gate text, and a `nil` answer
        /// (infrastructure failure) reads as "has entry" while flagging the
        /// pass degraded.
        func gate(_ surface: String) -> Bool {
            guard let answer = headwordGate(Self.gateText(surface)) else {
                gateDegraded = true
                return true
            }
            return answer
        }
        let result = segments.flatMap { segment -> [ReadingSegment] in
            guard isFragmentable(segment, gate: gate) else { return [segment] }
            if let pieces = segment.mergePieces {
                return seamFragments(of: pieces, pos: segment.pos, gate: gate)
            }
            let pieces = fragments(of: segment.surface, gate: gate)
            // A pass that would re-emit the source surface whole is a no-op
            // by definition; single-piece surfaces (pure punctuation runs,
            // for instance) stay unfragmented.
            guard pieces.count >= 2 else { return [segment] }
            return pieces.map { piece in emitFragment(piece, pos: segment.pos) }
        }
        return (result, gateDegraded)
    }

    /// Splits a sokuon-merged segment at its original token seams — stem
    /// included — instead of guessing a cut through the merged surface.
    /// Short pieces render with the merge's own kana (the reading the whole
    /// segment carried, minus gemination across the seam); a freak long
    /// absorbed token re-runs the generic splitter. The merge always
    /// absorbs at least one token, so at least two segments emerge.
    private func seamFragments(
        of pieces: [ReadingSegment.MergePiece], pos: String?, gate: (String) -> Bool
    ) -> [ReadingSegment] {
        pieces.flatMap { piece -> [ReadingSegment] in
            guard piece.surface.unicodeScalars.count < Self.fragmentLengthThreshold else {
                return fragments(of: piece.surface, gate: gate)
                    .map { cut in emitFragment(cut, pos: pos) }
            }
            return [emitFragment(piece.surface, kana: piece.kana, pos: pos)]
        }
    }

    /// Eligibility, cheap scan first and I/O last: the segment must be long
    /// enough to bother, carry Japanese script, not be a numeral run, be
    /// self-transcribed (the unknown marker: no lemma, no furigana), and the
    /// whole surface must miss the dictionary — a JMDict/JMnedict-covered
    /// name the tokenizer lexicon lacks stays whole.
    private func isFragmentable(_ segment: ReadingSegment, gate: (String) -> Bool) -> Bool {
        guard segment.surface.unicodeScalars.count >= Self.fragmentLengthThreshold else {
            return false
        }
        guard KanaClassification.containsJapanese(segment.surface) else { return false }
        guard !Self.isNumeralRun(segment.surface) else { return false }
        guard segment.lemma == nil, segment.furigana == nil else { return false }
        return !gate(segment.surface)
    }

    /// The text a headword probe runs against: true NFKC so halfwidth
    /// katakana (ﾊﾟｲﾅｯﾌﾟﾙ) folds onto the fullwidth spellings the
    /// dictionary stores. The compatibility mapping alone decomposes
    /// (ﾊﾟ → ハ + ゛) and never recomposes, so canonical composition
    /// finishes the fold — without it the byte-wise SQL probe would miss
    /// the precomposed row. Fullwidth probes are unchanged by the fold,
    /// so memo keys dedupe the two widths.
    private static func gateText(_ text: String) -> String {
        ReadingAlignment.compatibilityComposed(text)
    }

    /// Splits a fragmenting surface into piece strings: script runs first,
    /// then dictionary-guided and structural cuts within kana/kanji runs.
    /// Pieces concatenate back to `surface` byte-identically.
    func fragments(of surface: String, gate: (String) -> Bool) -> [String] {
        var pieces: [String] = []
        for (text, kind) in Self.scriptRuns(of: surface) {
            switch kind {
            case .other:
                // Punctuation, Latin, digits: always its own fragment, never
                // cut further (a middle-dot row stays whole this way).
                pieces.append(text)
            case .kana, .kanji:
                let scalars = Array(text.unicodeScalars)
                // Runs that fit whole are never probed.
                var emitted: [[Unicode.Scalar]] = []
                var remainder = scalars
                if scalars.count > Self.fragmentLengthThreshold {
                    (emitted, remainder) = dictionaryCutPieces(of: scalars, gate: gate)
                }
                pieces.append(contentsOf: emitted.map(Self.scalarString))
                if let chunks = Self.structuralChunks(of: remainder) {
                    pieces.append(contentsOf: chunks)
                } else if !remainder.isEmpty {
                    pieces.append(Self.scalarString(remainder))
                }
            }
        }
        return pieces
    }

    /// Dictionary-guided cuts along a run longer than the threshold: at each
    /// frontier the longest dictionary-covered prefix (probing lengths
    /// threshold…2) is emitted and consumed; the first frontier where no
    /// prefix hits ends the pass, handing the remainder to the structural
    /// fallback. Bounded by construction — ≤ 7 probes per frontier, every
    /// hit consumes ≥ 2 scalars — and the gate memoizes every answer.
    private func dictionaryCutPieces(
        of scalars: [Unicode.Scalar], gate: (String) -> Bool
    ) -> (emitted: [[Unicode.Scalar]], remainder: [Unicode.Scalar]) {
        var frontier = 0
        var emitted: [[Unicode.Scalar]] = []
        while scalars.count - frontier > Self.fragmentLengthThreshold {
            guard let hit = dictionaryHit(in: scalars, from: frontier, gate: gate) else { break }
            emitted.append(Array(scalars[frontier ..< hit]))
            frontier = hit
        }
        return (emitted, Array(scalars[frontier...]))
    }

    /// The end offset of the longest covered prefix at `frontier`, probing
    /// lengths threshold…2, or nil when none hits.
    private func dictionaryHit(
        in scalars: [Unicode.Scalar], from frontier: Int, gate: (String) -> Bool
    ) -> Int? {
        for length in stride(from: Self.fragmentLengthThreshold, through: 2, by: -1) {
            let end = frontier + length
            guard end <= scalars.count else { continue }
            let prefix = Self.scalarString(Array(scalars[frontier ..< end]))
            if gate(prefix) {
                return end
            }
        }
        return nil
    }

    /// Structural fallback for a remaining run, highest-confidence pattern
    /// first. Period-1 and repetition fire at any length (a repeated unit is
    /// garble however the dictionary pass trimmed the run); the balanced cap
    /// — the low-precision shape guess — only fires at threshold length and
    /// above, so shorter leftovers stay whole.
    private static func structuralChunks(of scalars: [Unicode.Scalar]) -> [String]? {
        if let chunks = periodOneChunks(of: scalars) {
            return chunks
        }
        if let chunks = repetitionChunks(of: scalars) {
            return chunks
        }
        guard scalars.count >= fragmentLengthThreshold else { return nil }
        return balancedChunks(
            of: scalars,
            count: max(2, (scalars.count + fragmentLengthThreshold - 1) / fragmentLengthThreshold)
        )
    }

    /// A single kana scalar repeated (いいいいいいいい): balanced chunks of
    /// at most 3 scalars. Checked before the repetition search — otherwise
    /// period 2 shadows it for even/composite lengths (い×8 → いい×4) and
    /// the chunk shape would flip by parity. Needs more than one chunk to
    /// apply; a ≤ 3 run stays whole.
    private static func periodOneChunks(of scalars: [Unicode.Scalar]) -> [String]? {
        guard let first = scalars.first, scalars.count > 3,
              KanaClassification.isKana(first),
              scalars.allSatisfy({ scalar in scalar == first })
        else { return nil }
        let count = (scalars.count + 2) / 3
        return balancedChunks(of: scalars, count: count)
    }

    /// Smallest period (2…6 scalars) whose units tile the whole run with at
    /// least two repeats (のじゃのじゃのじゃ → のじゃ ×3). Exact scalar
    /// comparison only — no hiragana/katakana folding, so the cut stays
    /// deterministic.
    private static func repetitionChunks(of scalars: [Unicode.Scalar]) -> [String]? {
        let count = scalars.count
        guard count >= 4 else { return nil }
        for period in 2 ... min(6, count / 2) where count % period == 0 {
            let unit = scalars[0 ..< period]
            let repeats = count / period
            guard (1 ..< repeats).allSatisfy({ repeatIndex in
                scalars[repeatIndex * period ..< (repeatIndex + 1) * period].elementsEqual(unit)
            }) else { continue }
            return (0 ..< repeats).map { repeatIndex in
                scalarString(scalars[repeatIndex * period ..< (repeatIndex + 1) * period])
            }
        }
        return nil
    }

    /// Splits into `count` near-equal chunks of `ceil(n / count)` scalars —
    /// every chunk within the cap, sizes balanced (n=17, count=3 → 6+6+5).
    private static func balancedChunks(
        of scalars: [Unicode.Scalar], count: Int
    ) -> [String] {
        let size = (scalars.count + count - 1) / count
        return stride(from: 0, to: scalars.count, by: size).map { start in
            scalarString(scalars[start ..< min(start + size, scalars.count)])
        }
    }

    // MARK: - Script runs

    private enum ScriptKind {
        /// Hiragana and katakana as ONE cutting class (splitting them would
        /// shred モいモい into single characters); the middle dot ・ rides
        /// inside the katakana block but is punctuation, so it cuts.
        case kana
        case kanji
        /// Punctuation, Latin, digits — always a run break.
        case other
    }

    private static func scriptKind(_ scalar: Unicode.Scalar) -> ScriptKind {
        if KanaClassification.isHiragana(scalar)
            || (KanaClassification.isKatakana(scalar) && scalar.value != 0x30FB)
        {
            return .kana
        }
        if KanaClassification.isKanji(scalar) {
            return .kanji
        }
        return .other
    }

    /// Partitions into maximal runs of one script kind; an "other" scalar
    /// breaks the run it sits in.
    private static func scriptRuns(of text: String) -> [(text: String, kind: ScriptKind)] {
        var runs: [(text: String, kind: ScriptKind)] = []
        var current: [Unicode.Scalar] = []
        var currentKind: ScriptKind?
        func flush() {
            if let kind = currentKind, !current.isEmpty {
                runs.append((scalarString(current), kind))
            }
            current = []
            currentKind = nil
        }
        for scalar in text.unicodeScalars {
            let kind = scriptKind(scalar)
            if kind != currentKind {
                flush()
                currentKind = kind
            }
            current.append(scalar)
        }
        flush()
        return runs
    }

    // MARK: - Fragment emission

    /// Renders a fragment through the token pipeline's full override chain —
    /// never a bare kana→romaji conversion. Kana fragments read themselves;
    /// kanji-bearing fragments consult the reading fallback, and a miss
    /// leaves them self-transcribed exactly like an unread token. Seam
    /// pieces inject the merge's own kana instead (a gap-prefixed surface
    /// can't read itself). Fragments carry no lemma (they are not
    /// dictionary words) and inherit the source segment's part of speech.
    private func emitFragment(
        _ fragment: String, kana: String? = nil, pos: String?
    ) -> ReadingSegment {
        var reading = kana ?? Self.selfReading(fragment)
        if reading == nil, KanaClassification.containsKanji(fragment) {
            reading = readingFallback(fragment)
        }
        let fields = Self.annotatedFields(surface: fragment, reading: reading)
        return ReadingSegment(
            surface: fragment, romaji: fields.romaji, furigana: fields.furigana,
            lemma: nil, pos: pos
        )
    }

    private static func scalarString(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }
}
