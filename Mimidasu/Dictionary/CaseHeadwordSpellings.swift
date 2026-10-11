import Foundation

/// Every stored headword spelling that is not already lowercase, paired with
/// the form a query has to be folded into before it can reach it.
///
/// `normalize` lowercases every query and the ladder probes spellings
/// verbatim, so a case-bearing spelling — `ActiveX`, `iPhone`, `TKG` — is
/// unreachable from the search box: the exact seek probes the folded spelling,
/// the B-tree's BINARY order puts `ActiveX` outside the range of `activex`
/// (the divergence is decided at scalar 1, long before the appended
/// `U+10FFFF` sentinel), and the uppercase spelling the literal candidates
/// carry alongside rescues only the all-caps half. The tap path is unaffected —
/// `JMDictLookup.probeText` folds NFKC and nothing else — which is why `Ajax`
/// and `Airbnb` are findable by tapping and not by typing. No population stays
/// out of reach: the rescue runs on both branches, so a spelling whose fold
/// carries kana (`1Dayコンタクト`) answers through its own exact fold on the
/// Japanese branch, and through a kana-free prefix (`1day` opens it, prefix
/// tier) on either.
///
/// The population is small and known: **2,357 distinct spellings** of the
/// 1,289,637 `headwords` rows on the pinned build — 2,263 from the ASCII
/// load, 94 more from the range scan — 1,182 of them pure ASCII Latin. So
/// this is a side set — loaded once per engine, answered by binary search —
/// and not an index the ladder consults per keystroke. Folding the whole
/// table instead walks all 1.29M rows (`LIKE`, `COLLATE NOCASE`); this
/// answers off 2,357 of them.
///
/// Nothing here changes ranking. A spelling this set hands back is probed
/// exactly the way a typed spelling is, and its tier says only whether the
/// fold matched exactly or merely opened the spelling.
struct CaseHeadwordSpellings: Sendable {
    /// One spelling the folded query reaches.
    struct Match: Equatable, Sendable {
        let spelling: String
        /// True when the spelling folds to the query itself rather than merely
        /// being opened by it — the exact-tier half. `iPhone` is an exact
        /// match for `iphone` and a prefix match for `iph`, and the two tiers
        /// rank differently.
        let isExact: Bool
    }

    /// Sorted by fold, so one folded query is one contiguous range.
    private let folds: [String]
    private let spellings: [String]

    /// The set a query carries nothing to match against — what a caller with
    /// no database open passes, and what tests pass when they exercise the
    /// matching rules without a corpus.
    static let empty = CaseHeadwordSpellings(spellings: [])

    init(db: SQLiteDatabase) throws {
        var texts: [String] = []
        for sql in [JMDictCaseIndex.loadSQL, JMDictCaseIndex.nonASCIICaseLoadSQL] {
            let statement = try db.statement(sql)
            while try statement.step() {
                guard let text = statement.optionalText(0) else { continue }
                texts.append(text)
            }
        }
        self.init(spellings: texts)
    }

    /// Builds a set straight from spellings, folding and sorting each the way
    /// the database load does. The seam the unit tests drive — a set over a
    /// literal list needs no database, and going through `init(db:)` would put
    /// a corpus scan in front of every assertion about prefix behaviour.
    init(spellings texts: [String]) {
        var unique: [(fold: String, spelling: String)] = []
        var seen: Set<String> = []
        for text in texts where seen.insert(text).inserted {
            unique.append((DictionarySearchEngine.normalize(text), text))
        }
        // Neither load returns an order (`DISTINCT` over the B-tree happens to,
        // but that is not a contract), and candidate order is what a diff of
        // two searches compares — so the sort is what makes the emitted order
        // deterministic, not the query. The spelling breaks the tie because
        // Swift's sort is not stable and two spellings can share a fold
        // (`ActiveX` and `ACTIVEX`), and an unstable order between them would
        // make the same query emit its candidates differently per run.
        unique.sort { lhs, rhs in
            lhs.fold == rhs.fold ? lhs.spelling < rhs.spelling : lhs.fold < rhs.fold
        }
        folds = unique.map(\.fold)
        spellings = unique.map(\.spelling)
    }

    /// Every spelling the set holds.
    ///
    /// The load is a deliberate **superset** of what Swift's fold would select,
    /// so this is how a test audits it against the corpus: what the set
    /// reaches, rather than what one query happened to ask for.
    var reachableSpellings: Set<String> {
        Set(spellings)
    }

    /// The spellings a folded query reaches: those folding to it exactly, and
    /// those it opens as a prefix. Empty for an empty query — nothing folds to
    /// the empty string except an empty spelling, and there is none.
    func matches(openingFold fold: String) -> [Match] {
        guard !fold.isEmpty else { return [] }
        // The sentinel turns the "opens the spelling" prefix into a range, the
        // same move `headwordRows` makes against the B-tree.
        let start = lowerBound(fold)
        let end = lowerBound(fold + DictionarySearchEngine.scalarRangeCeiling)
        guard end > start else { return [] }
        var out: [Match] = []
        for index in start ..< end {
            // The range narrows the search; `hasPrefix` is the contract. Swift
            // ordering folds some scalars away (a combining mark weighs
            // nothing), so a bound can overshoot what the query actually opens
            // — and a spelling that does not open is not a match. The one
            // shape the filter cannot rescue runs the other way: a fold that
            // extends the query by a bare combining mark sorts past the
            // sentinel and is never reached. No such spelling survives
            // `normalize`'s composition on this corpus; the corpus guard test
            // is what goes red if one ever does.
            guard folds[index].hasPrefix(fold) else { continue }
            out.append(Match(spelling: spellings[index], isExact: folds[index] == fold))
        }
        return out
    }

    /// Index of the first element not ordered before `key`.
    private func lowerBound(_ key: String) -> Int {
        var low = 0
        var high = folds.count
        while low < high {
            let mid = low + (high - low) / 2
            if folds[mid] < key {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
