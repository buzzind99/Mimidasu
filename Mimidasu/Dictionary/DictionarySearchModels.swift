import Foundation

/// What a dictionary search is allowed to return. Pure value types so the
/// engine can stay free of UI state and a test can pin a filter set without a
/// window.
struct DictionarySearchFilters: Equatable, Sendable {
    /// Which half of the database answers. Names are not "a separate
    /// dictionary" here — they are the same tables above the ingest offset —
    /// so the scope is a predicate on `ent_seq`, not a different database.
    enum Scope: Equatable, Sendable, CaseIterable, Identifiable {
        case all
        case words
        case names

        var id: String {
            label
        }

        var label: String {
            switch self {
            case .all: "All"
            case .words: "Words"
            case .names: "Names"
            }
        }
    }

    var scope: Scope = .all
    /// Restrict to entries JMDict marks common. Name entries are never common,
    /// so this and `.names` are structurally empty — the UI greys the toggle
    /// out rather than showing a filter that can only answer zero.
    var commonOnly = false

    /// Whether `entSeq` falls in this scope. The boundary is the JMnedict
    /// ingest offset, the same one `DictionaryContent.nameSeqOffset` reads.
    func admits(entSeq: Int) -> Bool {
        switch scope {
        case .all: true
        case .words: entSeq < DictionaryContent.nameSeqOffset
        case .names: entSeq >= DictionaryContent.nameSeqOffset
        }
    }
}

/// One ranked dictionary hit.
///
/// `highlightRange` is a **Unicode-scalar** offset range into the field named
/// by `matchedField` (the engine's own convention — see `MatchHighlight`), and
/// it is nil for a lemma hit: a lemmatized query (`負けた` → 負ける) matched
/// something the user did not type, so the badge explains it and no text is
/// lit up.
struct DictionarySearchHit: Identifiable, Equatable, Sendable {
    /// How the hit was found, which is also its rank tier: exact beats
    /// lemma beats prefix beats gloss, gloss subdividing into
    /// word-boundary / gloss-prefix / substring.
    enum MatchKind: Int, Equatable, Sendable, CaseIterable {
        case exact = 0
        case lemma = 1
        case prefix = 2
        case glossWordBoundary = 3
        case glossPrefix = 4
        case glossSubstring = 5

        /// The chip the row shows. Every tier reads as a *reason* the row is
        /// here, which is what the user needs in order to trust a hit they did
        /// not type.
        var badgeLabel: String {
            switch self {
            case .exact: "EXACT"
            case .lemma: "LEMMA"
            case .prefix: "PREFIX"
            case .glossWordBoundary, .glossPrefix, .glossSubstring: "GLOSS"
            }
        }
    }

    /// Which rendered field the highlight lands in. Exactly one per row, so a
    /// result can never light up two places and imply two matches.
    enum MatchedField: Equatable, Sendable {
        /// The entry's kanji writing (`keb`).
        case keb
        /// The entry's kana reading (`reb`).
        case reb
        /// The matched English gloss (`senses.gloss`).
        case gloss
    }

    let entSeq: Int
    let keb: String?
    let reb: String?
    let common: Bool
    let jlpt: Int?
    /// JMnedict name entry (ent_seq at or above the ingest offset).
    let isName: Bool
    /// The name entry's stored `pos` columns, in sense order — the type tags
    /// themselves, unmapped, so the UI holds the vocabulary. Empty for word
    /// entries and for names whose senses carry no tags.
    let namePosTokens: [String?]
    let matchKind: MatchKind
    let matchedField: MatchedField
    /// Unicode-scalar offsets into `matchedField`'s rendered text; nil for a
    /// lemma hit.
    let highlightRange: Range<Int>?
    /// The preview line's glosses, deduped and trimmed. For a gloss hit the
    /// *matched* sense leads, so `highlightRange` always points into a string
    /// the row actually renders.
    let glossPreview: [String]

    var id: Int {
        entSeq
    }

    /// The row's headword — the same `keb ?? reb` the favorite star keys on,
    /// so a search hit and a lookup of the same entry are one favorite.
    var headword: String? {
        keb ?? reb
    }
}

/// A completed search: every ranked row the stages that ran found, plus the
/// total behind them.
///
/// The header reads `displayed / matched` and the footer offers one more page
/// or says to refine — both need the count the rows do not carry, which a bare
/// array cannot express.
struct DictionarySearchOutcome: Equatable, Sendable {
    /// Every row the stages that ran found, ranked, bounded at
    /// `DictionarySearchEngine.maxRows`. The window is the UI's slice of this
    /// (`DictionarySearchState.visibleHits`) — paging reveals rows from here
    /// rather than searching again, so rows below the window cost nothing to
    /// show.
    let hits: [DictionarySearchHit]
    /// Total hits after filters, before the window — a lower bound when a stage's
    /// fetch ceiling truncated its own scan, or when a stage was skipped.
    let matchedCount: Int
    /// A stage was skipped because the window was already full of strictly
    /// better tiers, so the rows it would have found are not in `matchedCount`
    /// either. Paging is what makes that stage run: the first click whose
    /// window outgrows `hits` re-searches, and the total it reports is the one
    /// that jumps. That is why a saturated search offers a load-more even when
    /// it filled the window exactly and `matchedCount` does not exceed it, and
    /// why the header marks such a total with `+`.
    let saturated: Bool

    static let empty = DictionarySearchOutcome(hits: [], matchedCount: 0, saturated: false)

    var isEmpty: Bool {
        hits.isEmpty
    }
}

/// Why a search could not run at all. Deliberately distinct from "no matches":
/// the view shows a fault for this and a result card for that, because a
/// dictionary that failed to open is not an answer.
enum DictionarySearchError: Error, Equatable, Sendable {
    /// The prepared database is not on disk yet (still preparing, or never
    /// built).
    case databaseMissing
    /// `close()` was called on this engine.
    case databaseClosed
    /// SQLite reported a failure.
    case sqlite(code: Int32, message: String)
}

extension DictionarySearchError {
    /// Maps the generic SQLite failure onto the search's typed error surface —
    /// the same translation `JMDictLookup` performs for its own queries.
    init(_ error: SQLiteDatabase.Error) {
        switch error {
        case .unavailable:
            self = .databaseMissing
        case let .sqlite(code, message):
            self = .sqlite(code: code, message: message)
        }
    }
}
