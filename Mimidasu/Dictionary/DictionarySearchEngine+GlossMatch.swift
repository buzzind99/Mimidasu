import Foundation

/// Gloss-hit grading: the best match inside a stored sense column.
///
/// Split from `DictionarySearchEngine+Ladder.swift` — the ladder file was at
/// the length budget, and this grading is a cohesive unit (pure functions over
/// the folded column, no stage state). Everything is `internal`, not
/// `private`, because the ladder's gloss stage calls in and the
/// test-facing `glossMatchKind(gloss:range:)` is read by the internals suite.
extension DictionarySearchEngine {
    /// One matched gloss and the span inside it.
    struct GlossMatch {
        let gloss: String
        let range: Range<Int>?
        let kind: DictionarySearchHit.MatchKind
    }

    /// The best match inside a stored sense column: the tightest tier across
    /// every occurrence in every gloss, and the occurrence that carried it —
    /// what the row will render, so the highlight points at what it ranks.
    ///
    /// The fold here is the same case fold the gloss index's tokenizer
    /// applies, so a gloss it cannot locate is not a gloss the query
    /// reached. That agreement is no longer incidental — the index folds case
    /// across the whole Unicode range, so a row can match the index on a case
    /// difference the fold must then reproduce — and it is asserted against
    /// the real prepared database rather than assumed. The fallback covers the
    /// pathological case where the two folds still disagree: the row keeps its
    /// place without a highlight rather than dropping out of the results.
    static func glossMatch(pattern: String, column: String) -> GlossMatch {
        let byteCount = column.utf8.count
        // The fast path offsets into the *folded* text and then slices the
        // *original*, which only lines up when one scalar is one byte: then the
        // fold cannot change the count either, so a scalar offset is a byte
        // offset and a byte offset is a character offset. `K` (U+212A) is the
        // trap — it is not ASCII but folds to one, so testing the folded text
        // for ASCII would wrongly admit it; the column's own byte width is what
        // settles it. Everything else — an accented character, `İ` — takes the
        // fragment-wise path, which re-derives each gloss's scalars; the span
        // it emits counts folded offsets against unfolded text, exact only
        // while the fold keeps the scalar count. 36,413 of 656,706 senses (5.5%); `ing`, 389 of 52,172 (0.7%).
        guard byteCount == column.unicodeScalars.count else {
            return glossMatchByFragment(pattern: pattern, column: column)
        }
        let scalars = Array(column.lowercased().unicodeScalars)
        let needle = Array(pattern.lowercased().unicodeScalars)
        guard !scalars.isEmpty, !needle.isEmpty, scalars.count >= needle.count else {
            return glossMatchFallback(pattern: pattern, column: column)
        }

        var bestKind: DictionarySearchHit.MatchKind?
        var bestRange: Range<Int>?
        var bestBounds: Range<Int>?
        var fragmentStart = 0
        while fragmentStart < scalars.count, bestKind != .glossWordBoundary {
            let fragmentEnd = separatorStart(in: scalars, from: fragmentStart) ?? scalars.count
            // The build writes the gloss joiner between glosses and nothing
            // else, so a fragment's bounds end at that scalar — and trimming
            // its edges is a pair of walks, where `glossList` allocated a
            // substring for every one of the ~85,000 glosses a one-mora query
            // reaches.
            var lower = fragmentStart
            var upper = fragmentEnd
            while lower < upper, CharacterSet.whitespaces.contains(scalars[lower]) {
                lower += 1
            }
            while upper > lower, CharacterSet.whitespaces.contains(scalars[upper - 1]) {
                upper -= 1
            }
            fragmentStart = min(fragmentEnd + 1, scalars.count)

            // Every occurrence inside the fragment is graded, not just the
            // leftmost: in `iced (e.g. iced tea` the first `iced` opens the
            // gloss while the second stands alone — the occurrence that earns
            // the tier lends its span, so the highlight points at what ranks.
            var position = lower
            while let start = nextOccurrence(
                of: needle, in: scalars, within: lower ..< upper, from: position
            ) {
                let lowerBound = start - lower
                let upperBound = lowerBound + needle.count
                let kind = glossMatchKind(
                    scalars: scalars,
                    range: lowerBound ..< upperBound,
                    length: upper - lower,
                    offset: lower
                )
                // Only the winner's text is materialised. Every row the index
                // matches used to build a `String` here, to serve the thousand rows
                // `assemble` actually shows.
                if kind.rawValue < (bestKind?.rawValue ?? .max) {
                    bestKind = kind
                    bestRange = lowerBound ..< upperBound
                    bestBounds = lower ..< upper
                }
                // The best tier there is, and ties keep the first: nothing
                // later in the column can change the answer.
                if kind == .glossWordBoundary {
                    break
                }
                position = start + 1
            }
        }
        guard let bestKind, let bestRange, let bestBounds else {
            return glossMatchFallback(pattern: pattern, column: column)
        }
        return GlossMatch(
            // One scalar is one byte and one character here, so the scalar
            // bounds the scan produced are character bounds — a native
            // substring, not a re-encode. The two ends are the whole column
            // for most rows, and are taken without a walk.
            gloss: String(column[
                (bestBounds.lowerBound == 0 ? column.startIndex
                    : column.index(column.startIndex, offsetBy: bestBounds.lowerBound))
                    ..< (bestBounds.upperBound == scalars.count ? column.endIndex
                        : column.index(column.startIndex, offsetBy: bestBounds.upperBound))
            ]),
            range: bestRange,
            kind: bestKind
        )
    }

    /// The original fragment-wise grading, occurrence-wise like the fast path,
    /// kept for the columns whose fold changes their scalar offsets.
    static func glossMatchByFragment(pattern: String, column: String) -> GlossMatch {
        let needle = Array(pattern.lowercased().unicodeScalars)
        guard !needle.isEmpty else {
            return glossMatchFallback(pattern: pattern, column: column)
        }
        var best: GlossMatch?
        fragment: for gloss in glossList(column) {
            let scalars = Array(gloss.lowercased().unicodeScalars)
            var position = 0
            while let start = nextOccurrence(
                of: needle, in: scalars, within: 0 ..< scalars.count, from: position
            ) {
                let range = start ..< (start + needle.count)
                let kind = glossMatchKind(
                    scalars: scalars, range: range, length: scalars.count, offset: 0
                )
                let match = GlossMatch(gloss: gloss, range: range, kind: kind)
                if best == nil || kind.rawValue < (best?.kind.rawValue ?? .max) {
                    best = match
                }
                if kind == .glossWordBoundary {
                    break fragment
                }
                position = start + 1
            }
        }
        return best ?? glossMatchFallback(pattern: pattern, column: column)
    }

    /// A column whose fold reproduced none of its glosses. The hit keeps its
    /// place, spanned by the pattern's own length — over the column's first
    /// gloss, not the raw joined column, so the preview never carries the
    /// joiner and the highlight points at a string the row renders.
    static func glossMatchFallback(pattern: String, column: String) -> GlossMatch {
        let first = glossList(column).first ?? ""
        let scalars = first.unicodeScalars.count
        return GlossMatch(
            gloss: first,
            range: scalars == 0 ? nil : 0 ..< min(pattern.unicodeScalars.count, scalars),
            kind: .glossSubstring
        )
    }

    /// The first gloss joiner at or after `start`, or nil when the column ends
    /// first.
    static func separatorStart(
        in scalars: [Unicode.Scalar], from start: Int
    ) -> Int? {
        scalars[start...].firstIndex(of: JMDictPin.glossJoiner)
    }

    /// The first position at or after `start` where `needle` sits within
    /// `bounds`, or nil.
    static func nextOccurrence(
        of needle: [Unicode.Scalar],
        in scalars: [Unicode.Scalar],
        within bounds: Range<Int>,
        from start: Int
    ) -> Int? {
        var index = start
        while index + needle.count <= bounds.upperBound {
            if scalars[index ..< (index + needle.count)].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// The gloss sub-tiers: a whole-word match first, then one starting the
    /// gloss, then a bare substring — `"to lose"` outranks `"closet"` for the
    /// query `lose`. The stage grades through the array overload below, so this
    /// `String` form is test-facing only — shared grading, not an oracle or dependency.
    static func glossMatchKind(
        gloss: String, range: Range<Int>
    ) -> DictionarySearchHit.MatchKind {
        let scalars = Array(gloss.lowercased().unicodeScalars)
        return glossMatchKind(scalars: scalars, range: range, length: scalars.count, offset: 0)
    }

    /// The same grading against an already-folded scalar array, for a caller
    /// grading several fragments of one column out of a single array.
    ///
    /// `range` is relative to the matched gloss, but `scalars` is the whole
    /// column, so `offset` is where that gloss starts — the two keep the
    /// neighbour lookups pointing at the match's characters, not the column's.
    static func glossMatchKind(
        scalars: [Unicode.Scalar], range: Range<Int>, length: Int, offset: Int
    ) -> DictionarySearchHit.MatchKind {
        guard range.lowerBound > 0 else {
            return range.upperBound == length
                ? .glossWordBoundary
                : .glossPrefix
        }
        let opensCleanly = !isWordScalar(scalars[offset + range.lowerBound - 1])
        // A match at the very end of the gloss closes cleanly too.
        let closesCleanly = range.upperBound == length
            || !isWordScalar(scalars[offset + range.upperBound])
        guard opensCleanly, closesCleanly else { return .glossSubstring }
        return .glossWordBoundary
    }

    static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        Character(scalar).isLetter || Character(scalar).isNumber
    }
}
