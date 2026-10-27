import Foundation

/// What one tap becomes: pinnable content both the popover and the pinned
/// card read together from the first entry, a warning naming the tapped
/// word when nothing resolved at all, a typed fault routed to the feedback
/// sink as a toast (never as language fact), or a superseded lookup the
/// session drops silently.
enum TapLookupEffect: Equatable, Sendable {
    /// Pinnable display content. `entryIndex` is always 0 — the popover and
    /// the pinned card page together from the first entry, so the two
    /// surfaces never disagree.
    case show(content: LookupContent, entryIndex: Int)
    /// A no-hit: nothing resolved, nothing pins, and the feedback sink posts
    /// the amber warning naming `surface`.
    case warnNoHit(surface: String)
    /// An infrastructure failure: the feedback sink posts the dictionary
    /// lookup toast with the fault's message, never the warning.
    case fault(TapLookupFault)
    /// A superseded lookup (cancellation): nothing applies — no pin, no
    /// warning, no toast. Cancellation never surfaces as a fault.
    case cancelled
}
