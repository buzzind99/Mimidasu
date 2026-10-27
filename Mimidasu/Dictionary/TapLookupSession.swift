import Foundation
import Observation

/// The lookup engine behind a tap: resolves one request to an effect. The
/// dictionary layer's adapter is `LookupDisplay`; tests substitute a stub so
/// the session's dispatch and routing can be driven without a database.
protocol TapLookupResolving: Sendable {
    func resolve(_ request: TapLookupRequest, favorites: FavoriteIdentity) async -> TapLookupEffect
}

/// Where a lookup effect's user-facing feedback goes: a no-hit warning or a
/// fault returns through this port instead of the session owning notice copy.
@MainActor
protocol TapLookupFeedbackSink: AnyObject {
    func tapLookupDidWarnNoHit(surface: String)
    func tapLookupDidFail(_ fault: TapLookupFault)
}

/// Owns one tap-to-pin lifecycle: resolution dispatch, generation drops,
/// the presentation both hosts render, fallback promotion, pager clamping,
/// dismissal, and feedback routing.
///
/// Every tap asks the injected resolver off the main actor and keeps its
/// generation; a landing whose generation has since moved on is dropped whole
/// — no presentation change, no feedback. `clear()` advances the generation
/// too, so a lookup in flight at a session or pane boundary cannot land on the
/// next one. Staleness is a value check, not cancellation.
@Observable
@MainActor
final class TapLookupSession {
    /// The one lookup both the popover and the pinned card read; nil when no
    /// lookup has landed or after a clear.
    private(set) var presentation: LookupPresentation?
    /// Staleness token: every tap and clear advances it, and a landing effect
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
            let effect = await resolver.resolve(request, favorites: favorites)
            guard capturedGeneration == generation else { return }
            apply(effect, anchor: anchor)
        }
    }

    /// Dismisses the popover only when `anchor` owns it, so a stale binding
    /// from a row that has since scrolled away cannot close a newer popover.
    /// The pinned content and entry index stay.
    func dismissPopover(from anchor: LookupAnchor) {
        guard presentation?.anchor == anchor else { return }
        presentation?.anchor = nil
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

    /// Ends the current lookup surface: the presentation empties and an
    /// in-flight lookup is invalidated so it cannot present afterward.
    func clear() {
        presentation = nil
        generation &+= 1
    }

    /// The popover item `anchor` presents, or nil when no presentation is up
    /// or another anchor owns it.
    func popoverItem(for anchor: LookupAnchor) -> LookupPresentation? {
        presentation?.popoverItem(for: anchor)
    }

    private func apply(_ effect: TapLookupEffect, anchor: LookupAnchor) {
        switch effect {
        case let .show(content, entryIndex):
            presentation = .initial(content: content, entryIndex: entryIndex, anchor: anchor)
        case let .warnNoHit(surface):
            feedback?.tapLookupDidWarnNoHit(surface: surface)
        case let .fault(fault):
            feedback?.tapLookupDidFail(fault)
        case .cancelled:
            break
        }
    }
}

extension LookupDisplay: TapLookupResolving {}
