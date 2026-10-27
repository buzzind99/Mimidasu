import Foundation

/// Tap-to-verdict resolver: everything from a tap request to the answer the
/// session presents — resolution, defensive re-anchoring,
/// Display/Also/Related classification, and favorites promotion applied at
/// resolve time.
///
/// The dictionary lookup engine core, the expansion tables, and the
/// promotion rule are composed unchanged — behavior moved here, ranking
/// logic was not rewritten. Split-fallback hits never present themselves
/// as the tapped word: a tap whose only hits are splits resolves to
/// not-found content with those hits demoted to related suggestions, the
/// demotion the engine already performs.
///
/// Stateless by design: stale-generation drops belong to the session that
/// dispatches the tap, and favorites cross as one Favorite identity
/// snapshot taken before dispatch — the engine receives no
/// favorites parameter, so it cannot learn favorites exist. Queries run off
/// the main actor on a detached task; the session applies answers back on
/// the main actor.
final class LookupDisplay: Sendable {
    private let lookup: JMDictLookup

    /// Dependencies accepted, not created: the caller owns the engine (and
    /// its database location), this module only reads through it.
    init(lookup: JMDictLookup) {
        self.lookup = lookup
    }

    /// Resolves one tap to its answer. An empty surface fails as
    /// annotator-unavailable whatever the segments carry — no empty-named
    /// pill ever posts; a nil-segments request otherwise answers a no-hit
    /// with the tapped surface, and an empty-segments request (the annotator
    /// ran without its dictionary) fails as annotator-unavailable. Otherwise
    /// the stored index re-anchors against drift — failing closed to no-hit
    /// through the expansion's bounds guard — and the engine lookup runs
    /// off-main on a detached task. A found answer promotes favorites into
    /// the returned content; a not-found resolves only when its related
    /// suggestions are non-empty (a bare miss answers no-hit instead),
    /// promoting each related hit in place while the content itself stays
    /// not-found with no display result; any throw fails; a cancellation
    /// answers nil so the session drops it silently.
    func resolve(_ request: TapLookupRequest, favorites: FavoriteIdentity) async -> LookupAnswer? {
        guard !request.surface.isEmpty else {
            return .failure(.annotatorUnavailable)
        }
        guard let segments = request.segments else {
            return .noHit(surface: request.surface)
        }
        guard !segments.isEmpty else {
            return .failure(.annotatorUnavailable)
        }
        let tappedAt = Self.reAnchoredTapIndex(
            stored: request.tappedAt, surface: request.surface, in: segments
        )
        let engine = lookup
        let sentenceText = request.sentenceText
        let resolved: LookupAnswer
        do {
            // Detached by design (off-main even when the host is already
            // backgrounded): inherits no cancellation, so rapid double-taps
            // pile serial SQLite work behind the engine Mutex while the host
            // drops all but the latest on landing. A child Task would inherit
            // cancellation; kept detached as a deliberate trade, noted as
            // perf debt. Nothing cancels this task today — the engine's
            // cancellation checks and the catch below are defensive, there
            // for a future caller that retains and cancels the handle.
            resolved = try await Task.detached(priority: .userInitiated) {
                try engine.lookup(
                    segments: segments, tappedAt: tappedAt, sentenceText: sentenceText
                )
            }.value
        } catch is CancellationError {
            return nil
        } catch {
            return .failure(DictionaryError(error))
        }
        guard let content = Self.content(
            for: resolved, surface: request.surface, favorites: favorites
        ) else {
            return .noHit(surface: request.surface)
        }
        return content
    }

    /// The tap-time index for a tap request's stored render-time index.
    /// TEST SEAM — the session calls resolve, never this. Callers must not
    /// re-implement drift logic — resolve is the only production caller.
    /// Kept verbatim while the request's segments still agree with the
    /// stored index — the overwhelmingly common case. A request that drifted
    /// (a fragmentation decision that flipped across a dictionary-state
    /// transition) re-anchors to the first segment whose surface matches
    /// the tapped surface — the accepted recovery for in-bounds drift and
    /// duplicate surfaces (first occurrence wins). No match points one past
    /// the end — the expansion's bounds guard then fails the tap closed
    /// instead of looking up whatever drifted into the stored slot. Resolve
    /// short-circuits nil/empty before calling this; the guard below covers
    /// direct callers and tests only.
    static func reAnchoredTapIndex(
        stored: Int, surface: String, in segments: [LookupSegment]?
    ) -> Int {
        guard let segments, !segments.isEmpty else { return stored }
        let agrees = segments.indices.contains(stored)
            && segments[stored].surface == surface
        if agrees {
            return stored
        }
        return segments.firstIndex(where: { segment in segment.surface == surface })
            ?? segments.count
    }

    /// The content a resolved tap returns, or nil when nothing resolved at
    /// all — a not-found resolution without related hits is a bare miss, and
    /// answers a no-hit instead of presenting an empty card. A found content
    /// also leads on a favorited entry written or read as the tapped word
    /// where one exists, so tapping a word the user has studied opens the
    /// study instead of the homograph above it. A not-found result stays
    /// not-found with no display result, but each related suggestion is
    /// promoted the same way, so a buried eligible favorite leads its pill
    /// before any re-select. The not-found surface is restamped from the
    /// request — the tapped word the user asked about, which is what every
    /// host names. The engine answers only found and not-found, so a no-hit
    /// or a failure reaching this point passes through untouched.
    private static func content(
        for resolved: LookupAnswer, surface: String, favorites: FavoriteIdentity
    ) -> LookupAnswer? {
        switch resolved {
        case .found:
            FavoritesPromotion.promotingFavorites(in: resolved, identity: favorites)
        case let .notFound(_, related):
            related.isEmpty ? nil : .notFound(surface: surface, related: related.map { result in
                FavoritesPromotion.promotingFavorites(in: result, identity: favorites)
            })
        case .noHit, .failure:
            resolved
        }
    }
}
