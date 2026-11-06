import SwiftUI

/// One transcript row: mono start timestamp in a fixed-width gutter,
/// JP sentence with the configured reading annotation, and the EN
/// translation marked by a gradient capsule bar.
///
/// Every property is a plain value snapshot rather than a settings wrapper:
/// `@AppStorage`-backed wrappers read the *live* stored value, so a row would
/// render the previous annotation mode or scale unless its parent handed it a
/// fresh value. The row carries no `Equatable` witness, so a parent
/// invalidation re-renders it outright; the nested `RubyTextView` keeps its
/// own value diff and repaints through its body's own reads of the matcher and
/// popover closures.
struct TranscriptRow: View {
    /// Shared label for the one retry affordance: the row's named
    /// accessibility action and the hover button's help tag must not drift.
    static let retryActionTitle = "Re-translate this line"

    let entry: SessionEntry
    /// Archive mode's viewed language: the row renders that language's
    /// translation alone. Nil (the live pane) keeps the joined
    /// multi-language line.
    let displayLanguage: String?
    /// Snapshot, not a settings wrapper — see the note above.
    let annotation: ReadingAnnotation
    let scale: UIScale
    let cursorMode: CursorMode
    let onCopy: (String) -> Void
    /// Invoked with the lookup request built from the rendered segments when
    /// cursor mode is `.dictionary`; nil keeps `.dictionary` on the legacy
    /// rendering path.
    var onLookup: ((TapLookupRequest) -> Void)?
    /// The anchor word's popover presentation resolver, invoked only when
    /// `lookupAnchorToken` matches that word's segment index. The binding
    /// getter it returns is read by the anchor word's `.popover` leaf, where
    /// the presentation observation registers.
    var lookupPopover: ((Int) -> RubyTextView.LookupPopover)?
    /// The row's popover anchor reader: resolves the live presentation's
    /// anchor for this sentence, so only that word receives the host's
    /// popover binding. The reader's own body carries the presentation read.
    var lookupAnchorToken: () -> Int?
    var isFavorite: ((ReadingSegment) -> Bool)?
    /// Invoked with the row's sentence when the hover retry button fires.
    var onRetry: ((Sentence) -> Void)?
    /// The row's re-translate decision: whether the retry affordance may be
    /// shown, whether the sentence is already retranslating, and the
    /// provenance suffix for the translation the row shows. The plan is
    /// built by the transcript from the current surface, target, and live
    /// evidence; the enabled flag already folds in every precondition a
    /// click would enforce, so a shown button is always one that would be
    /// served rather than silently refused.
    let rowPlan: RetranslateRowPlan
    /// True only while this row is the live feed's newest entry: a freshly
    /// appended row fades in, while older rows render opaque so recycled
    /// rows scrolling back into view don't re-fade. A record's rows never
    /// fade, and a mounted row promoted to newest (a shorter transcript
    /// reused it) is revealed by the change handler below because
    /// `onAppear` will not fire again.
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
                rubyText
                    .textSelection(.enabled)

                translationRow
                    // A manual re-translation dims the stale line (bar and
                    // placeholder alike) until the fresh one lands; applied
                    // here rather than inside `translationRow` so it covers
                    // both branches, and above the overlay so the button
                    // itself never dims.
                    .opacity(rowPlan.isRetranslating ? 0.45 : 1)
                    // The retry button floats left of the bar: overlay-only
                    // (no layout impact), vertically centered on the
                    // translation block whatever its line count.
                    .overlay(alignment: .leading) {
                        if hovering, rowPlan.isEnabled {
                            retryButton
                                // Pointer-only: the row's named action above
                                // is the VoiceOver/keyboard path, and the
                                // button in the tree would duplicate it.
                                .accessibilityHidden(true)
                                .offset(x: -32)
                        }
                    }
            }
        }
        // Generous row spacing stands in for a divider.
        .padding(.bottom, 24)
        // Opacity only: animating layout would displace neighboring rows
        // while the re-anchor chase is also repositioning content.
        .opacity(fadesIn && !shown ? 0 : 1)
        // The hover-revealed retry button is pointer-only: it is hidden from
        // the accessibility tree even while rendered (see `retryButton`), so
        // the same affordance is exposed as a named custom action on the row
        // itself — the non-pointer path to the feature.
        .accessibilityAction(named: Text(Self.retryActionTitle)) {
            guard rowPlan.isEnabled else { return }
            onRetry?(entry.sentence)
        }
        .onHover { isHovering in hovering = isHovering }
        .onAppear {
            guard fadesIn, !shown else { return }
            withAnimation(.easeOut(duration: 0.25)) { shown = true }
        }
        .onChange(of: fadesIn) { _, wantsFade in
            guard wantsFade, !shown else { return }
            withAnimation(.easeOut(duration: 0.25)) { shown = true }
        }
        .onDisappear { hovering = false }
    }

    /// The sentence view, scoped to the host's current popover anchor. Every
    /// row's reader re-runs when the presentation changes; only the rows
    /// whose token changed re-run the `RubyTextView` body.
    private var rubyText: some View {
        TranscriptRowLookupAnchor(token: lookupAnchorToken) { token in
            rubyTextView(popoverAnchorToken: token)
        }
    }

    /// `.equatable()` keeps the wrapped `RubyTextView` body out of
    /// parent-driven updates when its value inputs did not change; the body's
    /// own observation reads still re-run it directly.
    private func rubyTextView(popoverAnchorToken: Int?) -> some View {
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
            popoverAnchorToken: popoverAnchorToken,
            isFavoriteSegment: isFavorite
        )
        .equatable()
    }

    /// The hover-revealed retry button: floats 32pt left of the translation
    /// text — right edge 3pt clear of the 3pt bar — vertically centered on
    /// the translation block whatever its height. Overlay-only, so zero
    /// layout impact. Both branches of `translationRow` anchor it at the same
    /// edge (the placeholder's leading padding expands its frame outward, so
    /// it does not shift the button).
    ///
    /// That 32pt exceeds the 14pt gap between the timestamp column and the
    /// text, so the disc deliberately overhangs the row's trailing timestamp
    /// digits at every UI scale. Accepted: it is pointer-driven and transient,
    /// it never touches the sentence or its translation, and the alternative —
    /// a gap wide enough to hold it — narrows the sentence column. It also
    /// lands clear of the timestamp on any row whose timestamp is short of
    /// its 40pt frame.
    ///
    /// Rendered only while the row is hovered and the row plan enables the
    /// retry: gating the overlay's *content* rather than its opacity keeps
    /// the button out of hit-testing when hidden, so it can neither eat a
    /// click meant for the transcript nor leave a phantom control per row.
    /// The button stays out of the accessibility tree even when rendered:
    /// VoiceOver and full keyboard access reach the same affordance through
    /// the row's named action, and a hover-only control in the tree would
    /// just duplicate it.
    private var retryButton: some View {
        Button {
            onRetry?(entry.sentence)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 18, height: 18)
                .contentShape(Circle())
                .hoverHighlight(Circle())
        }
        .buttonStyle(.plain)
        .help(Self.retryActionTitle)
        // Outermost, mirroring `TranscriptView.jumpButton`: buried under
        // `.disabled`/`.opacity`, the pointer style never took effect.
        .pointerStyle(.link)
    }

    @ViewBuilder
    private var translationRow: some View {
        if let shown = shownTranslation {
            // The bar overlays the text's leading edge so it stretches to the
            // full height of the (possibly multi-line) translation.
            translationText(shown)
                .font(.system(size: 13 * scale.factor))
                .textSelection(.enabled)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Gradients.translationBar)
                        .frame(width: 3)
                        .offset(x: -11)
                }
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

    /// The line the row renders: the viewed language's translation in
    /// archive mode — never the joined string, so an untranslated row keeps
    /// its placeholder however many other languages it holds — and the
    /// joined multi-language text live.
    private var shownTranslation: String? {
        guard let displayLanguage else { return entry.joinedTranslations }
        return entry.translation(for: displayLanguage)?.text
    }

    /// The translation with its provenance suffix when the row was retried
    /// through a different engine.
    ///
    /// Concatenated `Text` runs, not an `HStack`: layout trailing pins the
    /// suffix after a wrapped translation's FIRST line — visually
    /// mid-sentence — while a run inside the text trails the sentence's
    /// actual last line. Each run is styled before concatenation, so the
    /// suffix keeps its muted colour; styling the concatenation itself would
    /// repaint every run. Non-breaking spaces glue the suffix to the
    /// sentence's last word, so it can neither split internally nor wrap
    /// alone onto a new line. The trade of living inside the selectable
    /// text: the suffix copies with the sentence.
    private func translationText(_ text: String) -> some View {
        let translation = Text(text).foregroundStyle(Theme.translationTeal)
        guard let marker = rowPlan.marker else { return translation }
        let glued = marker.replacingOccurrences(of: " ", with: "\u{00A0}")
        let suffix = Text("\u{00A0}\u{00A0}\(glued)")
            .foregroundStyle(Theme.secondaryText)
        return translation + suffix
    }
}

/// Per-row reader for the transcript's word-popover anchor: the presentation
/// read lands in this view's body, so a tap invalidates the row's reader
/// instead of the row or every word unit.
private struct TranscriptRowLookupAnchor<Content: View>: View {
    let token: () -> Int?
    let content: (Int?) -> Content

    var body: some View {
        content(token())
    }
}
