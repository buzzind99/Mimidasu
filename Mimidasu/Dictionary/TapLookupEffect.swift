import Foundation

/// What one tap becomes: pinnable content both the popover and the pinned
/// card read together from the first entry, a warning pill naming the
/// tapped word when nothing resolved at all, a typed fault the host
/// surfaces as a toast (never as language fact), or a superseded lookup
/// the host drops silently.
enum TapLookupEffect: Equatable, Sendable {
    /// Pinnable display content. `entryIndex` is always 0 — the popover and
    /// the pinned card page together from the first entry, so the two
    /// surfaces never disagree.
    case show(content: LookupContent, entryIndex: Int)
    /// A no-hit: nothing resolved, nothing pins, and the host posts the
    /// amber warning pill naming `surface`.
    case warnNoHit(surface: String)
    /// An infrastructure failure: the host posts the dictionary-lookup
    /// toast with the fault's message, never the pill.
    case fault(TapLookupFault)
    /// A superseded lookup (cancellation): the host applies nothing — no
    /// pin, no pill, no toast. Cancellation never surfaces as a fault.
    case cancelled
}
