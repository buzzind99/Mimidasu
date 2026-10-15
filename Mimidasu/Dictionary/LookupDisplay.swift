import Foundation

/// Tap-to-pinnable-content: everything from a tap to the display the
/// popover, the pinned card, and the pill row read — resolution,
/// Display/Also/Related classification, favorite-first promotion, pill
/// re-promotion, and pager clamping.
///
/// The dictionary lookup engine core, the expansion tables, and the
/// promotion rule are composed unchanged — behavior moved here, ranking
/// logic was not rewritten. Split-fallback hits never present themselves
/// as the tapped word: a tap whose only hits are splits resolves to
/// not-found content with those hits demoted to related suggestions, the
/// demotion the engine already performs.
///
/// Stateless by design: stale-generation drops stay caller-side (each host
/// scope keeps its own guard), and favorites cross as a snapshot of
/// normalized headword keys taken before dispatch — the engine receives no
/// favorites parameter, so it cannot learn favorites exist. Queries run off
/// the main actor on a detached task; hosts apply outcomes back on the main
/// actor.
final class LookupDisplay: Sendable {
    private let lookup: JMDictLookup

    /// Dependencies accepted, not created: the caller owns the engine (and
    /// its database location), this module only reads through it.
    init(lookup: JMDictLookup) {
        self.lookup = lookup
    }

    /// Resolves one tap to its effect. An empty surface faults as
    /// annotator-unavailable whatever the segments carry — no empty-named
    /// pill ever posts; a nil-segments request otherwise warns with the
    /// tapped surface, and an empty-segments request (the annotator ran
    /// without its dictionary) faults as annotator-unavailable. Otherwise
    /// the stored index
    /// re-anchors against drift — failing closed to no-hit through the
    /// expansion's bounds guard — and the engine lookup runs off-main on a
    /// detached task. A found resolution promotes favorites into the pinned
    /// content; a not-found pins only when its related suggestions are
    /// non-empty (a bare miss warns instead), promoting each related hit's
    /// pager in place while the pin itself stays not-found with no display
    /// result; any throw faults.
    func resolve(_ request: TapLookupRequest, favorites: Set<String>) async -> TapLookupEffect {
        guard !request.surface.isEmpty else {
            return .fault(.annotatorUnavailable)
        }
        guard let segments = request.segments else {
            return .warnNoHit(surface: request.surface)
        }
        guard !segments.isEmpty else {
            return .fault(.annotatorUnavailable)
        }
        let tappedAt = Self.reAnchoredTapIndex(
            stored: request.tappedAt, surface: request.surface, in: segments
        )
        let engine = lookup
        let sentenceText = request.sentenceText
        let resolved: LookupResolution
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
            return .cancelled
        } catch {
            return .fault(TapLookupFault(error))
        }
        guard let content = Self.content(
            for: resolved, surface: request.surface, favorites: favorites
        ) else {
            return .warnNoHit(surface: request.surface)
        }
        return .show(content: content, entryIndex: 0)
    }

    /// Re-selects a fallback pill — an "also:" hit on a found card, or a
    /// "related:" suggestion on a not-found one: the content switches to
    /// that result as found, and the pill row recomputes from the retained
    /// results relative to the new selection — no new query runs. The
    /// promoted result carries the tapped-surface origin: an explicitly
    /// chosen hit is never labeled a fallback lead. The rebuilt content
    /// runs through the same favorites promotion a fresh tap gets, so a
    /// "related:" selection — which left its pin unpromoted — still opens
    /// on a favorited entry and hands out starred, relabeled pills.
    /// A re-selected fallback opens as the tapped word; a compound formed
    /// with following words loses its joined-match badge on a cross-pill
    /// move and regains nothing on the way back. Same-display re-select
    /// preserves origin. Promoting a foreign result — one the tap never
    /// resolved — fails closed by returning the content unchanged.
    func promote(
        _ choice: LookupResult, in content: LookupContent, favorites: Set<String>
    ) -> LookupContent {
        guard content.allResults.contains(choice) else { return content }
        if let display = content.displayResult, choice == display,
           case let .found(_, _, origin) = content
        {
            return FavoritesPromotion.promotingFavorites(
                in: .found(
                    result: choice,
                    also: content.allResults.filter { candidate in candidate != choice },
                    origin: origin
                ),
                keys: favorites
            )
        }
        let others = content.allResults.filter { candidate in candidate != choice }
        return FavoritesPromotion.promotingFavorites(
            in: .found(result: choice, also: others, origin: .tappedSurface),
            keys: favorites
        )
    }

    /// The paged entry index for `index` (clamped): nil when there is no
    /// content, or when the content is not-found and has no entries — the
    /// pager is inert there. Returns an index into the display result's
    /// entries, not an entry itself, despite the name (kept for the
    /// resolve / promote / steppedEntry trio).
    func steppedEntry(in content: LookupContent?, to index: Int) -> Int? {
        guard let entries = content?.displayResult?.entries, !entries.isEmpty
        else { return nil }
        return min(max(index, 0), entries.count - 1)
    }

    /// The tap-time index for a tap payload's stored render-time index.
    /// TEST SEAM — hosts call resolve, never this. Hosts must not
    /// re-implement drift logic — resolve is the only production caller.
    /// Kept verbatim while the re-resolved segments still agree with the
    /// payload — the overwhelmingly common case. A resolution that drifted
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

    /// The content a resolved tap pins, or nil when nothing resolved at all —
    /// a not-found resolution without related hits is a bare miss, and warns
    /// instead of pinning an empty card. A found content also leads on a
    /// favorited entry where its pager has one, so tapping a word the user
    /// has studied opens the study instead of the homograph above it. A
    /// not-found pin stays not-found with no display result, but each
    /// related suggestion is promoted the same way, so a buried favorite
    /// leads its pill before any re-select.
    private static func content(
        for resolved: LookupResolution, surface: String, favorites: Set<String>
    ) -> LookupContent? {
        switch resolved {
        case let .found(outcome):
            FavoritesPromotion.promotingFavorites(
                in: .found(
                    result: outcome.display, also: outcome.also,
                    origin: outcome.displayOrigin
                ),
                keys: favorites
            )
        case let .notFound(related):
            related.isEmpty ? nil : .notFound(surface: surface, related: related.map { result in
                FavoritesPromotion.promotingFavorites(in: result, keys: favorites)
            })
        }
    }
}
