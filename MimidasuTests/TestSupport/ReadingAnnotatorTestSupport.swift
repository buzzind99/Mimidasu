import Foundation
@testable import Mimidasu
import Testing

// MARK: - Fixtures (shared by the ReadingAnnotator suites)

/// A token spanning `text` at the scalar offset `start`, carrying the given
/// surface reading (nil means unknown/unreadable).
func token(
    _ text: String, start: Int, reading: String? = nil,
    base: String? = nil, pos: String? = nil
) -> DictionaryToken {
    DictionaryToken(
        text: text,
        start: start,
        end: start + text.unicodeScalars.count,
        reading: reading,
        base: base,
        pos: pos
    )
}

/// Contiguous tokens laid out left-to-right across the concatenated surfaces.
/// `bases` are optional per-surface dictionary base forms, for payloads whose
/// fixtures care about lemmas — `[nil]` per surface to say "no lemma", which is
/// why an empty `bases` cannot mean "all nil" and the length still has to be
/// spelled. A short array of either kind is a fixture bug, not a shorter
/// payload: both used to be silently truncated, which hid the mismatch behind
/// fewer tokens than surfaces, and a missing `base` surfaces much later as a
/// bogus "unresolved payload" rejection pointing at the implementation.
func tokens(
    _ surfaces: [String], readings: [String?], bases: [String?] = []
) -> [DictionaryToken] {
    precondition(
        readings.count == surfaces.count,
        "tokens(\(surfaces.count) surfaces, \(readings.count) readings)"
    )
    precondition(
        bases.isEmpty || bases.count == surfaces.count,
        "tokens(\(surfaces.count) surfaces, \(bases.count) bases)"
    )
    var start = 0
    return surfaces.indices.map { index in
        defer { start += surfaces[index].unicodeScalars.count }
        return token(
            surfaces[index], start: start, reading: readings[index],
            base: bases.indices.contains(index) ? bases[index] : nil
        )
    }
}

/// Tokens laid out across space-separated surfaces — ASR output spaces out
/// words, and the contiguous `tokens` helper can't express those gaps. Same
/// count check as `tokens`, for the same reason.
func spacedTokens(
    _ surfaces: [String], readings: [String?]
) -> [DictionaryToken] {
    precondition(
        readings.count == surfaces.count,
        "spacedTokens(\(surfaces.count) surfaces, \(readings.count) readings)"
    )
    var start = 0
    return zip(surfaces, readings).map { surface, reading in
        defer { start += surface.unicodeScalars.count + 1 }
        return token(surface, start: start, reading: reading)
    }
}

/// An annotator that replays canned tokens, independent of the runtime.
/// The reading fallback is inert by default so reading-less fixtures stay
/// deterministically unannotated; fallback suites inject their own. The
/// headword gate answers "has entry" by default so no fixture fragments;
/// fragmentation suites inject their own gate (a `nil` answer degrades:
/// "has entry", uncached render).
func makeAnnotator(
    _ canned: [DictionaryToken],
    readingFallback: @escaping @Sendable (String) -> String? = { _ in nil },
    headwordGate: @escaping @Sendable (String) -> Bool? = { _ in true }
) -> ReadingAnnotator {
    ReadingAnnotator(
        tokenize: { _ in canned }, readingFallback: readingFallback, headwordGate: headwordGate
    )
}

/// Compact [surface, romaji, furigana] rows for whole-segment assertions.
func describe(_ segments: [ReadingSegment]?) -> [[String?]] {
    segments?.map { segment in [segment.surface, segment.romaji, segment.furigana] } ?? []
}

/// Whether a token stream still lines up with the text it was cut from: spans
/// ascending and contiguous, each surface exactly the scalars its own span
/// names, nothing dropped and nothing uncovered that is not whitespace. The
/// property the join taps rely on — a stream that repeats or drops a scalar
/// breaks every anchored join.
///
/// Whitespace is the one thing allowed to go uncovered, at either end and
/// between tokens, because the real tokenizer is configured to skip it
/// (`ignore_space`) and a spaced ASR sentence legitimately arrives with holes.
/// So the tail is checked the same way as a gap rather than demanding full
/// coverage, which would reject a space-terminated sentence that the real
/// tokenizer would accept.
func tilesText(_ stream: [DictionaryToken], _ text: String) -> Bool {
    let scalars = Array(text.unicodeScalars)
    func uncovered(_ range: Range<Int>) -> Bool {
        range.allSatisfy { index in scalars[index].properties.isWhitespace }
    }
    var cursor = 0
    for token in stream {
        guard token.start >= cursor, token.end > token.start, token.end <= scalars.count,
              token.text == String(String.UnicodeScalarView(scalars[token.start ..< token.end]))
        else { return false }
        if token.start > cursor, !uncovered(cursor ..< token.start) {
            return false
        }
        cursor = token.end
    }
    return uncovered(cursor ..< scalars.count)
}
