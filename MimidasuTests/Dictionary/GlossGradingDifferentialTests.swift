import Foundation
@testable import Mimidasu
import Testing

/// The gloss stage grades every row a query matches, so a rewrite that is
/// merely *plausible* is worth nothing — it has to agree with the
/// fragment-wise grading it must match, on every row of the real corpus.
///
/// This is that proof. The reference below is that grading transcribed: fold,
/// split the column into glosses, locate **every** occurrence of the pattern
/// in each, grade each occurrence, and keep the tightest tier (ties keep the
/// first). Occurrences are located by a plainly-written loop rather than any
/// engine primitive, so a scanner bug cannot cancel itself out. Both run over
/// every sense column a probe matches, and the tier, the winning gloss, and
/// the span must be equal row for row.
///
/// It is also the test that earns its keep on the awkward rows: a match that
/// starts at the second gloss rather than the first (neighbour lookups that
/// would read the wrong side of the separator), a match inside a word at
/// column offset zero, and a column whose fold is not the identity.
///
/// Live-gated, like the recall suite: it needs the pinned prepared database.
@Suite("Gloss grading differential", .enabled(if: InstalledJMDict.url != nil))
struct GlossGradingDifferentialTests {
    /// Probes chosen to reach every branch: a prefix match, a whole-word match
    /// buried mid-column, and a substring match. All at least three characters
    /// — the trigram tokenizer answers nothing shorter, so a two-letter probe
    /// would compare zero rows and pass without testing anything.
    @Test(
        "the fast-path grading agrees with the occurrence-wise reference",
        arguments: ["ing", "ion", "the", "car", "lose", "eat", "ess", "tion"]
    )
    func agreesWithOccurrenceWiseGrading(probe: String) throws {
        let db = try SQLiteDatabase(path: #require(InstalledJMDict.url).path)
        defer { db.close() }
        let statement = try db.statement(DictionarySearchEngine.glossSQL)
        statement.bind(JMDictFTSIndex.phrase(probe), at: 1)
        statement.bind(0, at: 2)
        statement.bind(Int.max, at: 3)

        var compared = 0
        var mismatches: [String] = []
        while try statement.step() {
            let column = statement.optionalText(1) ?? ""
            let expected = Self.referenceMatch(pattern: probe, column: column)
            let actual = DictionarySearchEngine.glossMatch(pattern: probe, column: column)
            compared += 1
            guard actual.kind != expected.kind
                || actual.gloss != expected.gloss
                || actual.range != expected.range
            else { continue }
            // Cap the report: a systematic rewrite bug would otherwise produce
            // one failure string per row and bury the test output.
            if mismatches.count < 5 {
                mismatches.append(
                    """
                    column: \(column.debugDescription) \
                    expected: \(expected.kind)/\(expected.range.debugDescription) \
                    actual: \(actual.kind)/\(actual.range.debugDescription)
                    """
                )
            }
        }

        #expect(compared > 1000, "\(probe) matched only \(compared) rows")
        #expect(
            mismatches.isEmpty,
            Comment(rawValue: "\(mismatches.count) rows disagree:\n"
                + mismatches.joined(separator: "\n"))
        )
    }

    /// The fragment-wise grading, transcribed — every occurrence of the
    /// pattern per gloss is graded, not just the leftmost one. Locating is a
    /// plainly-written scan so the reference stays independent of the engine's
    /// scanner; the grading itself is the shared primitive.
    private static func referenceMatch(
        pattern: String, column: String
    ) -> DictionarySearchEngine.GlossMatch {
        let needle = Array(pattern.lowercased().unicodeScalars)
        var best: DictionarySearchEngine.GlossMatch?
        for gloss in DictionarySearchEngine.glossList(column) {
            let haystack = Array(gloss.lowercased().unicodeScalars)
            guard !needle.isEmpty, needle.count <= haystack.count else { continue }
            for start in 0 ... (haystack.count - needle.count)
                where haystack[start ..< (start + needle.count)].elementsEqual(needle)
            {
                let range = start ..< (start + needle.count)
                let kind = DictionarySearchEngine.glossMatchKind(gloss: gloss, range: range)
                let match = DictionarySearchEngine.GlossMatch(
                    gloss: gloss, range: range, kind: kind
                )
                if best == nil || kind.rawValue < best?.kind.rawValue ?? .max {
                    best = match
                }
            }
        }
        if let best {
            return best
        }
        let scalars = column.unicodeScalars.count
        return DictionarySearchEngine.GlossMatch(
            gloss: column,
            range: scalars == 0 ? nil : 0 ..< min(pattern.unicodeScalars.count, scalars),
            kind: .glossSubstring
        )
    }
}
