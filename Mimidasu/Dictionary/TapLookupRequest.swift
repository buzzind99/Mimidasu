import Foundation

/// One tap's lookup question: the value snapshots forward expansion
/// consumes, taken at tap time.
///
/// `segments` is nil when the tapped text was empty — there is nothing to
/// expand, and a nil request with a non-empty surface ends at the no-hit
/// pill path. An empty surface faults as annotator-unavailable whatever the
/// segments carry, so no empty-named pill can post, and empty segments —
/// the annotator ran without its dictionary, the tokenizer refused to run —
/// fault the same way. The shapes stay distinct so hosts route the pill and
/// the toast without guessing.
/// (The host Nils when the sentence text is empty; an empty surface with a
/// non-empty sentence never reaches expansion — the module gate faults it
/// first.)
struct TapLookupRequest: Equatable, Sendable {
    /// The rendered-annotation segment snapshot the tap resolved against:
    /// nil for empty tapped text (no-hit pill unless the surface is empty
    /// too), empty for an annotator that ran without its dictionary
    /// (annotator fault).
    let segments: [LookupSegment]?
    /// The stored render-time index into `segments` — the unit the user
    /// actually tapped. The module re-anchors it at resolve time when the
    /// re-resolved segments drifted, failing closed rather than defining
    /// the wrong word.
    let tappedAt: Int
    /// The full sentence text at tap time, against which expansion validates
    /// join adjacency.
    let sentenceText: String
    /// The tapped word as rendered — the surface the warning pill names when
    /// nothing resolves.
    let surface: String
}
