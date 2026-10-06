import SwiftUI

/// One transcript row: mono start timestamp in a fixed-width gutter,
/// JP sentence with the configured reading annotation, and the EN
/// translation marked by a gradient capsule bar.
///
/// Rows repaint because `TranscriptView.body` reads the observed state they
/// render from (`model.entries`, `model.pendingRetranslations`, the favorites
/// revision, the dictionary selection) — nothing diffs these values against a
/// previous copy. That is why every property here is a plain value snapshot
/// rather than a settings wrapper: `@AppStorage`-backed wrappers read the
/// *live* stored value, so a row would keep rendering the previous mode
/// unless the parent re-rendered it.
struct TranscriptRow: View {
    let entry: SessionEntry
    /// Snapshot, not a settings wrapper — see the note above.
    let annotation: ReadingAnnotation
    let scale: UIScale
    let cursorMode: CursorMode
    let onCopy: (String) -> Void
    /// Invoked with the tapped word when cursor mode is `.dictionary`;
    /// nil keeps `.dictionary` on the legacy rendering path.
    var onLookup: ((LookupToken) -> Void)?
    /// Per-word popover presentation resolver, invoked with a word unit's
    /// segment index (`RubyTextView.LookupPopover`). Resolved while the
    /// parent body evaluates, which is what registers the selection
    /// observation that refreshes the owning row's popover.
    var lookupPopover: ((Int) -> RubyTextView.LookupPopover)?
    var isFavorite: ((ReadingSegment) -> Bool)?
    /// Invoked with the row's sentence when the hover retry button fires.
    var onRetry: ((Sentence) -> Void)?
    /// Whether the retry affordance is live — only during a session that
    /// still has a translation worker (see `TranscriptView`).
    let retryEnabled: Bool
    /// True while a manual re-translation of this row's sentence is in
    /// flight: the current translation dims until the fresh one replaces it.
    let isRetranslating: Bool
    /// True only while this row is the newest entry: a freshly appended
    /// row fades in, while older rows render opaque so recycled rows
    /// scrolling back into view don't re-fade. The demotion to false (a
    /// newer row landed) re-renders the row so opacity is 1 by
    /// implementation, and a recycled row whose `shown` state was discarded
    /// can't re-fade — the `onAppear` guard fails on false.
    let fadesIn: Bool

    /// Fade state for a freshly appended row: starts transparent and
    /// eases to opaque on first appearance.
    @State private var shown = false
    /// True while the pointer is anywhere on the row — reveals the retry
    /// button, and gates its hit-testing so an invisible button never eats
    /// a click meant for the transcript. Local-only.
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(entry.startTimestamp)
                .font(.system(size: 11 * scale.factor, design: .monospaced))
                .foregroundStyle(Theme.gutterText)
                .frame(width: 40 * scale.factor, alignment: .trailing)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 5) {
                // RubyTextView renders .none as plain text, so one call
                // covers every annotation mode; selectable in all modes.
                RubyTextView(
                    text: entry.sentence.text,
                    annotation: annotation,
                    surfaceFont: .system(size: 22 * scale.factor),
                    annotationFont: .system(size: 11 * scale.factor, design: .monospaced),
                    furiganaFont: .system(size: 14 * scale.factor, design: .monospaced),
                    annotationColor: Theme.annotationPink,
                    cursorMode: cursorMode,
                    onCopy: onCopy,
                    onLookup: onLookup,
                    lookupPopover: lookupPopover,
                    isFavoriteSegment: isFavorite
                )
                .textSelection(.enabled)

                translationRow
                    // The retry button floats left of the bar: overlay-only
                    // (no layout impact), vertically centered on the
                    // translation block whatever its line count.
                    .overlay(alignment: .leading) {
                        retryButton
                            .offset(x: -32)
                    }
            }
        }
        // Generous row spacing stands in for a divider.
        .padding(.bottom, 24)
        // Opacity only: animating layout would displace neighboring rows
        // while the re-anchor chase is also repositioning content.
        .opacity(fadesIn && !shown ? 0 : 1)
        .onHover { isHovering in hovering = isHovering }
        .onAppear {
            guard fadesIn, !shown else { return }
            withAnimation(.easeOut(duration: 0.25)) { shown = true }
        }
    }

    /// The hover-revealed retry button: floats 32pt left of the translation
    /// text — right edge 3pt clear of the 3pt bar — vertically centered on
    /// the translation block whatever its height. Overlay-only, so zero
    /// layout impact, and attached outside the re-translation dim so the
    /// button itself never dims. On an untranslated row the anchor carries
    /// the placeholder's 11pt leading indent, so the button sits 11pt
    /// further left there; it stays inside the row's leading gutter either
    /// way.
    private var retryButton: some View {
        Button {
            onRetry?(entry.sentence)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18, height: 18)
                .hoverHighlight(Circle(), isEnabled: retryEnabled)
        }
        .buttonStyle(.plain)
        .pointerStyle(retryEnabled ? .link : nil)
        .disabled(!retryEnabled)
        .help("Re-translate this line")
        // Hidden-but-hittable would eat clicks meant for the transcript.
        .allowsHitTesting(hovering && retryEnabled)
        .opacity(hovering && retryEnabled ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder
    private var translationRow: some View {
        if let joined = entry.joinedTranslations {
            // The bar overlays the text's leading edge so it stretches to the
            // full height of the (possibly multi-line) translation.
            Text(joined)
                .font(.system(size: 13 * scale.factor))
                .foregroundStyle(Theme.translationTeal)
                .textSelection(.enabled)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Gradients.translationBar)
                        .frame(width: 3)
                        .offset(x: -11)
                }
                // A manual re-translation dims the stale line (bar included)
                // until the fresh one lands; text stays readable throughout.
                .opacity(isRetranslating ? 0.35 : 1)
                .animation(.easeOut(duration: 0.15), value: isRetranslating)
        } else {
            Text("…")
                .font(.system(size: 13 * scale.factor))
                .italic()
                .foregroundStyle(Theme.secondaryText.opacity(0.6))
                // Indent past the 3pt bar + 8pt gap so the placeholder lines
                // up with where the translation will land.
                .padding(.leading, 11)
        }
    }
}
