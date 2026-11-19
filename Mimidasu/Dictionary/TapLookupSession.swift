import Observation

/// The lookup engine behind a tap: resolves one request to an answer. The
/// dictionary layer's adapter is `LookupDisplay`; tests substitute a stub so
/// the session's dispatch and routing can be driven without a database.
protocol TapLookupResolving: Sendable {
    func resolve(_ request: TapLookupRequest, favorites: FavoriteIdentity) async -> LookupAnswer?
}

/// Where a lookup answer's user-facing feedback goes: a no-hit warning or a
/// failure returns through this port instead of the session owning notice copy.
@MainActor
protocol TapLookupFeedbackSink: AnyObject {
    func tapLookupDidWarnNoHit(surface: String)
    func tapLookupDidFail(_ fault: DictionaryError)
}

/// Owns one tap-to-pin lifecycle: resolution dispatch, generation drops,
/// the pinned presentation both hosts render, the popover anchor, fallback
/// promotion, pager clamping, dismissal, and feedback routing.
///
/// The pinned presentation and the popover anchor are separate observable
/// values on purpose: the pinned card outlives the popover, and pager steps
/// and fallback promotions write only the presentation. Transcript rows that
/// read the anchor alone are therefore not invalidated by either.
///
/// Every tap asks the injected resolver off the main actor and keeps its
/// generation; a landing whose generation has since moved on is dropped whole
/// — no presentation change, no feedback. `clear()` advances the generation
/// too, so a lookup in flight at a session or pane boundary cannot land on the
/// next one. Staleness is a value check, not cancellation.
@Observable
@MainActor
final class TapLookupSession {
    /// The pinned content and paged entry index both hosts read; nil when no
    /// lookup has landed or after a clear.
    private(set) var presentation: LookupPresentation?
    /// Where the popover is up: the tapped transcript word or the live strip;
    /// nil while it is dismissed. Paging and fallback promotion never write it.
    private(set) var anchor: LookupAnchor?
    /// Staleness token: every tap and clear advances it, and a landing answer
    /// applies only when its captured value still matches.
    private var generation = 0
    @ObservationIgnored weak var feedback: (any TapLookupFeedbackSink)?

    @ObservationIgnored private let resolver: any TapLookupResolving

    init(resolver: any TapLookupResolving) {
        self.resolver = resolver
    }

    /// Starts one lookup from `anchor`. The caller gets the task so it can
    /// await the landing when it needs to; production callers drop it.
    @discardableResult
    func tap(
        _ request: TapLookupRequest, anchor: LookupAnchor, favorites: FavoriteIdentity
    ) -> Task<Void, Never> {
        generation &+= 1
        let capturedGeneration = generation
        return Task { @MainActor [weak self] in
            guard let self else { return }
            let answer = await resolver.resolve(request, favorites: favorites)
            guard capturedGeneration == generation else { return }
            apply(answer, anchor: anchor)
        }
    }

    /// Clears the popover ownership only when the calling surface owns it, so
    /// a stale binding from a row that has since scrolled away cannot close a
    /// newer popover. The pinned content and entry index stay.
    func dismissPopover(from anchor: LookupAnchor) {
        guard self.anchor == anchor else { return }
        self.anchor = nil
    }

    /// Re-selects a fallback pill over the current presentation. A foreign
    /// result and an unchanged promotion are no-ops; a promoted move keeps
    /// the current anchor, dismissed included.
    func selectFallback(_ result: LookupResult, favorites: FavoriteIdentity) {
        guard let current = presentation,
              let promoted = current.promoting(result, favorites: favorites)
        else { return }
        presentation = promoted
    }

    /// Advances the pager, clamped into the display entries.
    func stepEntry(to index: Int) {
        presentation?.stepEntry(to: index)
    }

    /// Ends the current lookup surface: the anchor empties before the
    /// presentation, so a presented popover never renders nil content, and an
    /// in-flight lookup is invalidated so it cannot present afterward.
    func clear() {
        anchor = nil
        presentation = nil
        generation &+= 1
    }

    /// The popover item `anchor` presents, or nil when the popover is down or
    /// another anchor owns it.
    func popoverItem(for anchor: LookupAnchor) -> LookupPresentation? {
        self.anchor == anchor ? presentation : nil
    }

    /// Routes a landed answer: only the pinnable two pin, at the first entry
    /// (the popover and the pinned card page together from there); a no-hit
    /// warns and a failure toasts through the feedback sink; a dropped
    /// (nil) answer — a superseded lookup — applies nothing at all: no pin,
    /// no warning, no toast. Cancellation never surfaces as feedback.
    ///
    /// The content is written before the anchor, and an unchanged anchor is
    /// left alone: the owning row never observes a nil presentation behind an
    /// up popover, and a same-anchor re-tap does not invalidate readers of the
    /// anchor alone.
    private func apply(_ answer: LookupAnswer?, anchor: LookupAnchor) {
        guard let answer else { return }
        switch answer {
        case .found, .notFound:
            presentation = .initial(content: answer, entryIndex: 0)
            if self.anchor != anchor {
                self.anchor = anchor
            }
        case let .noHit(surface):
            feedback?.tapLookupDidWarnNoHit(surface: surface)
        case let .failure(error):
            feedback?.tapLookupDidFail(error)
        }
    }
}

extension LookupDisplay: TapLookupResolving {}
