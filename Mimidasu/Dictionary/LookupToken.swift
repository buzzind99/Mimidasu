import Foundation

/// A tapped word in annotated Japanese text: the payload `RubyTextView`
/// hands its host when cursor mode is `.dictionary`. `tokenIndex` is the
/// index into the rendered `ReadingAnnotator.segments` array — the forward
/// expansion unit — and `sentenceText` is the full sentence text at render
/// time, against which expansion validates adjacency.
struct LookupToken: Equatable, Sendable {
    /// The tapped segment's surface as rendered.
    let surface: String
    /// Position of the tapped segment in the rendered segments array.
    let tokenIndex: Int
    /// The full sentence text the tap rendered from.
    let sentenceText: String
}
