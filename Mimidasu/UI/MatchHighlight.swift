import Foundation

/// Scalar-offset slicing for the search results' match highlight.
///
/// Every span in the app is a range of **Unicode scalars**, never
/// `String.Index` or `Character` offsets: the dictionary hands back UTF-8
/// byte-adjacent text the tokenizer never normalized, and a `Character`
/// offset (a grapheme cluster — a voiced kana plus its mark, a kana plus ー)
/// would drift the moment a folded spelling and the rendered spelling
/// disagree about where the match starts. `DictionaryToken` states the same
/// discipline for the same reason.
///
/// The two halves of a highlight must agree: *compare* folded (hiragana and
/// katakana are the same text for matching purposes) but *slice* the original
/// (the user sees アルバイト, not ある的时间和).
enum MatchHighlight {
    /// The three runs one highlighted field is drawn from.
    struct Parts: Equatable {
        let before: String
        let match: String
        let after: String
    }

    /// Splits `text` into the part before the match, the match itself, and
    /// the part after. Out-of-range and inverted ranges clamp rather than trap:
    /// a stale span from a row that re-rendered must not take the window down.
    static func split(_ text: String, at range: Range<Int>) -> Parts {
        let scalars = Array(text.unicodeScalars)
        let lower = min(max(range.lowerBound, 0), scalars.count)
        let upper = min(max(range.upperBound, lower), scalars.count)
        return Parts(
            before: String(String.UnicodeScalarView(scalars[0 ..< lower])),
            match: String(String.UnicodeScalarView(scalars[lower ..< upper])),
            after: String(String.UnicodeScalarView(scalars[upper...]))
        )
    }

    /// The scalar range of `pattern`'s first case-insensitive occurrence in
    /// `text`, or nil when it does not occur.
    ///
    /// Case-insensitive because the gloss stage's SQL folds case: a query for
    /// `lose` matching `Lose` must highlight the same run that ranked, or the
    /// badge would point at a highlight the user cannot see. The contract is
    /// that this fold agrees with the index tokenizer's, so that every row the
    /// gloss stage returns is a row whose span can be located — the stage's
    /// unreachable fallback depends on it. The needle is ASCII in practice, so
    /// lower-casing preserves scalar count and the range stays valid for the
    /// original string.
    ///
    /// The candidate scan compares slices in place rather than materialising
    /// each one. The gloss stage grades every row a query matches — uncapped,
    /// that is tens of thousands per keystroke — and allocating a fresh
    /// `Array` per candidate position made this quadratic in allocations for
    /// work that is a plain element-wise comparison.
    static func range(of pattern: String, in text: String) -> Range<Int>? {
        let needle = Array(pattern.lowercased().unicodeScalars)
        guard !needle.isEmpty else { return nil }
        let haystack = Array(text.lowercased().unicodeScalars)
        guard needle.count <= haystack.count else { return nil }
        for start in 0 ... (haystack.count - needle.count)
            where haystack[start ..< (start + needle.count)].elementsEqual(needle)
        {
            return start ..< (start + needle.count)
        }
        return nil
    }
}
