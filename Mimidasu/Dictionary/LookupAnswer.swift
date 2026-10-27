import Foundation

/// What a finished dictionary lookup answers with: a hit with its display
/// result, the retained "also:" fallback hits, and the origin the display
/// result came from (a join lead is labeled; a tap-promoted pill reads as
/// the tapped word); a not-found — the tapped word has no entry — with the
/// deep split fallback hits demoted to "related:" suggestions; a bare miss
/// with nothing to present; or a typed failure carrying why the lookup
/// could not run.
enum LookupAnswer: Equatable, Sendable {
    /// A hit: the display result, the retained "also:" fallback hits, and
    /// the role the display result played.
    case found(result: LookupResult, also: [LookupResult], origin: ExpansionOrigin)
    /// The tapped word has no entry: no display result, with the deep
    /// fallback hits demoted to "related:" suggestions.
    case notFound(surface: String, related: [LookupResult])
    /// A bare miss: nothing resolved for the surface — no hit and no
    /// related suggestions to offer.
    case noHit(surface: String)
    /// The lookup could not run; carries why.
    case failure(DictionaryError)

    /// The display result when found; nil otherwise.
    var displayResult: LookupResult? {
        switch self {
        case let .found(result, _, _): result
        case .notFound, .noHit, .failure: nil
        }
    }

    /// The demoted fallback hits: "also:" for a found answer, "related:"
    /// for a not-found one; empty for a bare miss or a failure.
    var fallbackResults: [LookupResult] {
        switch self {
        case let .found(_, also, _): also
        case let .notFound(_, related): related
        case .noHit, .failure: []
        }
    }

    /// The display result followed by the demoted fallback hits — the full
    /// result set a fallback-pill re-selection filters against.
    var allResults: [LookupResult] {
        (displayResult.map { display in [display] } ?? []) + fallbackResults
    }
}
