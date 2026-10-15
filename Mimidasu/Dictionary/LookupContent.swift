import Foundation

/// The content a finished lookup pins, shared by the popover selection and
/// the sidebar card: a hit with its display result, the retained "also:"
/// fallback hits, and the origin the display result came from (a join lead
/// is labeled; a tap-promoted pill reads as the tapped word); or a
/// not-found tap — the tapped word has no entry — with the deep split
/// fallback hits demoted to "related:" suggestions.
enum LookupContent: Equatable, Sendable {
    case found(result: LookupResult, also: [LookupResult], origin: ExpansionOrigin)
    case notFound(surface: String, related: [LookupResult])

    /// The display result when found.
    var displayResult: LookupResult? {
        switch self {
        case let .found(result, _, _): result
        case .notFound: nil
        }
    }

    /// The demoted fallback hits: "also:" for a found state, "related:"
    /// for a not-found one.
    var fallbackResults: [LookupResult] {
        switch self {
        case let .found(_, also, _): also
        case let .notFound(_, related): related
        }
    }

    /// The display result followed by the demoted fallback hits — the full
    /// result set a fallback-pill re-selection filters against.
    var allResults: [LookupResult] {
        (displayResult.map { display in [display] } ?? []) + fallbackResults
    }
}
