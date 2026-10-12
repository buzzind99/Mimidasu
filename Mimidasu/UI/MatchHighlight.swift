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
/// (the user sees アルゴリズム, never the folded あるごりずむ).
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
    /// gloss stage returns is a row whose span can be located.
    ///
    /// The offsets are into the **folded haystack**, and the caller slices the
    /// original, so the fold has to preserve scalar count on both sides. The
    /// needle is ASCII in practice and says nothing about the haystack: a gloss
    /// carrying `İ` (U+0130) lowercases to `i` + U+0307, one scalar becoming
    /// two, and every span at or after it shifts. The gloss stage does not use
    /// this — it grades in its own `glossMatch`/`glossMatchByFragment`, which
    /// derive the column's (or each gloss's) scalars themselves — and the
    /// corpus carries no such row;
    /// `DictionarySearchEngine+Ladder`'s note on the fragment path states the
    /// same caveat where the production code lives.
    ///
    /// It survives as an **oracle** in the tests, not a stage dependency:
    /// `JMDictGlossIndexRecallTests.everyIndexedRowGradesASpan` checks every
    /// row the index returns against it, and `DictionarySearchEngineTests`
    /// cross-checks the stage's `highlightRange` against it — an independent
    /// implementation, deliberately not the stage's own fold. What that pins
    /// is the contract the stage's whole-column fallback rests on: a span the
    /// tokenizer admits can be located by a fold built the same way.
    ///
    /// The candidate scan compares slices in place rather than materialising
    /// each one — a property the grade path this was written for needs, since
    /// it runs over every row a query matches, uncapped, tens of thousands per
    /// keystroke, where a fresh `Array` per candidate position would be
    /// quadratic in allocations for work that is a plain element-wise
    /// comparison.
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
