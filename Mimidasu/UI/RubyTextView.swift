import AppKit
import SwiftUI

// The wrapping flow engine (`RubyFlowPacking` + `FlowLayout`) lives in
// `RubyFlowLayout.swift`.

/// Ruby-style annotation: each kana/kanji word renders with its romaji
/// beneath it (or kana furigana above it), wrapping like normal text. Runs
/// without a distinct reading (punctuation, Latin, digits; kanji runs whose
/// romaji doesn't reverse to kana) render inline as plain text, so their
/// surfaces stay top-aligned with annotated words on the same line.
/// Consecutive plain runs fold into a single flow child.
struct RubyTextView: View, Equatable {
    let text: String
    var annotation: ReadingAnnotation = .romaji
    var surfaceFont: Font
    var annotationFont: Font
    /// Overrides `annotationFont` for the kana reading shown above the
    /// surface in furigana mode; romaji keeps `annotationFont`. Falls back
    /// to `annotationFont` when unset.
    var furiganaFont: Font?
    var annotationColor: Color
    var surfaceItalic = false
    /// Opt-in for hosts whose slot must hold a fixed geometry: when set, every
    /// unit — annotated or plain, in every annotation mode — reserves the
    /// annotation line above the surface (the visible furigana in furigana
    /// mode, invisible in romaji/none). The surface then starts at the same
    /// vertical position in None, Romaji, and Furigana modes, so mode toggles
    /// never shift the kanji. Off by default; the HUD's live partial opts in.
    var reservesAnnotationLine = false
    /// Whether render-time segment resolutions go through the annotator's
    /// cache. Hosts rendering a live partial — a growing 6–10 Hz revision of
    /// the in-flight sentence — opt out: every revision is a distinct string
    /// that will never be queried again, so caching it only churns the
    /// store. The tap-time re-resolution (`AppModel.handleLookupTap`) stays
    /// cached regardless. Excluded from `==` (no effect on rendered output).
    var cachesSegments = true
    /// Click behavior for surfaces (sidebar "cursor mode"): `.copy` invokes
    /// `onCopy` with the clicked run; `.dictionary` opens a definition
    /// lookup for the tapped word via `onLookup` (falling back to this
    /// legacy path where the host passes no handler); `.none` leaves
    /// clicks inert.
    var cursorMode: CursorMode = .none
    /// Invoked with the clicked surface text when `cursorMode == .copy`; the
    /// host owns the pasteboard write and the confirmation toast.
    var onCopy: ((String) -> Void)?
    /// Invoked with the tapped word when `cursorMode == .dictionary` and a
    /// token-derived surface is clicked; the host owns the lookup, its
    /// result presentation, and error surfacing. When nil, `.dictionary`
    /// renders the legacy path and taps stay inert (the HUD).
    var onLookup: ((LookupToken) -> Void)?
    /// Per-word popover presentation for the transcript host: invoked with
    /// a word unit's segment index at render time; a non-nil result
    /// attaches `.popover` to that word, and only the anchor word's
    /// binding is true, so the arrow points at the word. nil — the HUD,
    /// the live strip — keeps word units popover-free. Excluded from `==`
    /// (closures carry no value identity); the host's anchor field covers
    /// the data change that must re-render the row.
    var lookupPopover: ((Int) -> LookupPopover?)?
    /// Whether a rendered segment is a favorite; the host supplies the
    /// matcher (the store's in-memory key set) and the color follows wherever
    /// this view already renders per-segment surfaces. nil — any host that
    /// passes no matcher — leaves every surface its inherited host color.
    var isFavoriteSegment: ((ReadingSegment) -> Bool)?
    /// Bumped by `FavoritesStore` on every membership change, and part of
    /// `==`: `isFavoriteSegment` is a closure with no value identity, so
    /// without this the view compares equal to its previous value across a
    /// star toggle and SwiftUI skips the subtree that has to repaint.
    var favoritesRevision: Int = 0

    /// One word unit's popover presentation, resolved by the host per
    /// segment index: the binding presents only while that word is the
    /// selection's anchor; the content is the shared entry view (nil until
    /// a selection lands — the binding is false then, so nothing presents).
    struct LookupPopover {
        let isPresented: Binding<Bool>
        let content: DictionaryPopoverView?
    }

    /// Dictionary mode is active only when the host handles lookups; with
    /// `onLookup == nil` (the HUD) it falls back to the legacy path and
    /// taps stay inert.
    var dictionaryLookupActive: Bool {
        cursorMode == .dictionary && onLookup != nil
    }

    /// One child of the dictionary-mode flow layout. Every annotator
    /// segment is its own unit — token-derived words tappable, whitespace
    /// and punctuation inert — with no plain-run folding, so the unit's
    /// position in the array is the tapped segment index.
    enum SegmentedUnit: Equatable {
        /// A token-derived segment: tappable in dictionary mode, annotated
        /// when `note` is set (furigana above / romaji beneath per mode).
        case word(surface: String, note: String?)
        /// Whitespace or punctuation: renders plain, never tappable.
        case inert(surface: String)
    }

    /// Pure segment→child mapping for the dictionary path: a segment is
    /// inert when it is whitespace-only or carries no letter or number
    /// (punctuation); everything else is a tappable word — including
    /// reading-less kanji, whose tap falls back to a surface query. The
    /// note follows the annotation mode and is shown only when it differs
    /// from the surface, matching the legacy path's annotated-unit rule.
    static func segmentedUnits(
        for segments: [ReadingSegment], annotation: ReadingAnnotation
    ) -> [SegmentedUnit] {
        segments.map { segment in
            let surface = segment.surface
            let inert = surface.allSatisfy(\.isWhitespace)
                || !surface.contains(where: { scalar in scalar.isLetter || scalar.isNumber })
            guard !inert else { return .inert(surface: surface) }
            let note: String? = switch annotation {
            case .none: nil
            case .furigana: segment.furigana
            case .romaji: segment.romaji
            }
            return .word(surface: surface, note: note == surface ? nil : note)
        }
    }

    /// The body the dictionary path renders for the resolved segments: the
    /// flow of per-segment units, or the plain fallback when the annotator
    /// yielded nothing at all (nil — unresolvable text — or empty, the
    /// tokenizer-dictionary-unavailable case), so the row never blanks.
    /// Pure for tests.
    enum SegmentedBodyPlan: Equatable {
        case flow([SegmentedUnit])
        case plain
    }

    static func segmentedBodyPlan(
        segments: [ReadingSegment]?, annotation: ReadingAnnotation
    ) -> SegmentedBodyPlan {
        guard let segments, !segments.isEmpty else { return .plain }
        return .flow(segmentedUnits(for: segments, annotation: annotation))
    }

    /// The tap payload for segment `index`: surface, best-known reading,
    /// lemma, segment index, and the full sentence text. Pure over the
    /// given segments; the tap path passes the segments the body rendered,
    /// so the payload describes the unit the user actually tapped even
    /// when the host's tap-time re-resolution drifted.
    static func lookupToken(
        at index: Int, text: String, segments: [ReadingSegment]?
    ) -> LookupToken? {
        guard let segments, segments.indices.contains(index) else { return nil }
        let segment = segments[index]
        return LookupToken(
            surface: segment.surface,
            reading: segment.furigana,
            lemma: segment.lemma,
            tokenIndex: index,
            sentenceText: text
        )
    }

    private struct SurfaceText: View {
        let text: String
        let font: Font
        var italic = false
        var hoverColor = Theme.accentPink
        /// Overrides the inherited foreground — the favorite color. nil must
        /// stay a *shape-style* nil, not `Color.primary`: with
        /// `baseColor: Color?` the ternary's contextual type is `Color?`, so
        /// `.primary` would resolve to an opaque, scheme-dependent color that
        /// ignores the host's `.foregroundStyle` override and turns the HUD's
        /// white surfaces black-on-black in light appearance. The explicit
        /// `AnyShapeStyle.init` keeps the nil branch as
        /// `HierarchicalShapeStyle.primary`, which is what inherits.
        var baseColor: Color?
        var action: (() -> Void)?

        @State private var hovering = false
        /// Stand-down flag from the floating favorite-list button: hover is
        /// not exclusive, so without this the surface would light up while
        /// the cursor is on the button above it. Nil where no button exists.
        @Environment(\.favoritesButtonHover) private var favoritesButtonHover

        var body: some View {
            let suppressed = favoritesButtonHover?.isHovering == true
            let base: AnyShapeStyle = baseColor.map(AnyShapeStyle.init)
                ?? AnyShapeStyle(.primary)
            Text(verbatim: text)
                .font(font)
                .italic(italic)
                // Hover stays authoritative over the favorite color: it is the
                // tap affordance, and the star stand-down only suppresses it
                // for the surfaces under the floating button.
                .foregroundStyle(hovering && !suppressed ? AnyShapeStyle(hoverColor) : base)
                .textSelection(.disabled)
                .onHover { isHovering in hovering = isHovering }
                .pointerStyle(action == nil ? nil : .link)
                .onTapGesture { action?() }
        }
    }

    private func hoverableSurface(
        _ text: String, isFavorite: Bool = false, action: (() -> Void)? = nil
    ) -> some View {
        SurfaceText(
            text: text, font: surfaceFont, italic: surfaceItalic,
            baseColor: isFavorite ? Theme.favoriteAccent : nil,
            action: action
        )
    }

    /// The surface action on the legacy path: copy-on-click in `.copy`
    /// mode, inert otherwise.
    private func copyAction(_ text: String) -> (() -> Void)? {
        guard cursorMode == .copy else { return nil }
        return { onCopy?(text) }
    }

    /// The surface action for a dictionary-mode word unit: builds the
    /// payload from the segments this body render resolved — the units on
    /// screen — so the tapped surface survives a tap-time resolution that
    /// drifted; the host's re-anchor then maps the stored index into the
    /// fresh resolution or fails the tap closed.
    private func lookupAction(at index: Int, segments: [ReadingSegment]) -> (() -> Void)? {
        guard let onLookup else { return nil }
        let text = text
        return {
            guard let token = Self.lookupToken(
                at: index, text: text, segments: segments
            ) else { return }
            onLookup(token)
        }
    }

    var body: some View {
        if dictionaryLookupActive {
            segmentedBody
        } else {
            annotatedBody
        }
    }

    /// Plain full-text rendering: nothing annotatable (legacy path) or no
    /// segments at all (dictionary path — the tokenizer dictionary is
    /// unavailable), so the raw text keeps the slot filled. Taps stay
    /// inert outside `.copy`.
    @ViewBuilder
    private func plainFallback(_ text: String) -> some View {
        if reservesAnnotationLine {
            VStack(spacing: 0) {
                reservedAnnotationLine
                hoverableSurface(text, action: copyAction(text))
            }
        } else {
            hoverableSurface(text, action: copyAction(text))
        }
    }

    /// Legacy path: annotation-folded units, or plain text when nothing is
    /// annotatable. The HUD and every non-dictionary mode render here.
    ///
    /// "Nothing to show" is annotated *or* favorited, not annotated alone: in
    /// furigana mode a sentence with no kanji anywhere yields only plain units,
    /// so gating on annotation alone dropped the favorites those sentences carry
    /// — the commonest ones — on the floor.
    @ViewBuilder
    private var annotatedBody: some View {
        let units = displayUnits
        if annotation != .none,
           units.contains(where: { unit in unit.isAnnotated || unit.isFavorite })
        {
            FlowLayout(spacing: 4, lineSpacing: 1, fingerprint: fingerprint) {
                ForEach(Array(units.enumerated()), id: \.offset) { _, unit in
                    unitView(unit)
                }
            }
        } else {
            plainFallback(text)
        }
    }

    /// Dictionary path: one tappable unit per annotator segment — no
    /// plain-run folding, so the flow child's index is the tapped segment
    /// index. With no segments the plain fallback renders instead. The
    /// resolved segments ride along to the tap actions: the payload must
    /// describe what was rendered, not what a later resolution returns.
    @ViewBuilder
    private var segmentedBody: some View {
        let segments = ReadingAnnotator.segments(for: text, caching: cachesSegments) ?? []
        switch Self.segmentedBodyPlan(segments: segments, annotation: annotation) {
        case let .flow(units):
            FlowLayout(spacing: 4, lineSpacing: 1, fingerprint: fingerprint) {
                ForEach(Array(units.enumerated()), id: \.offset) { index, unit in
                    segmentedUnitView(unit, at: index, segments: segments)
                }
            }
        case .plain:
            plainFallback(text)
        }
    }

    @ViewBuilder
    private func segmentedUnitView(
        _ unit: SegmentedUnit, at index: Int, segments: [ReadingSegment]
    ) -> some View {
        // The index is the segment index: this path never folds plain runs,
        // so a unit's position in the array is its segment's position.
        let favorite = isFavoriteSegment?(segments[index]) == true
        switch unit {
        case let .word(surface, note):
            wordUnit(surface, note: note, isFavorite: favorite, index: index, segments: segments)
        case let .inert(surface):
            plainUnit(surface, isFavorite: favorite, action: nil)
        }
    }

    /// A tappable word unit, with the host's `.popover` attached when it
    /// provides one. The modifier stays attached to every word unit for
    /// stable identity — the binding is false (and the content nil) for
    /// all but the anchor word.
    @ViewBuilder
    private func wordUnit(
        _ surface: String, note: String?, isFavorite: Bool, index: Int,
        segments: [ReadingSegment]
    ) -> some View {
        let action = lookupAction(at: index, segments: segments)
        if let popover = lookupPopover?(index) {
            wordContent(surface, note: note, isFavorite: isFavorite, action: action)
                .popover(isPresented: popover.isPresented) {
                    if let content = popover.content {
                        content
                    }
                }
        } else {
            wordContent(surface, note: note, isFavorite: isFavorite, action: action)
        }
    }

    @ViewBuilder
    private func wordContent(
        _ surface: String, note: String?, isFavorite: Bool, action: (() -> Void)?
    ) -> some View {
        if let note {
            annotatedUnit(surface, note: note, isFavorite: isFavorite, action: action)
        } else {
            plainUnit(surface, isFavorite: isFavorite, action: action)
        }
    }

    /// Excludes `onCopy`, `onLookup`, `lookupPopover`, and `isFavoriteSegment`
    /// (closures have no value identity). The changes they serve arrive as
    /// values: favorite membership as `favoritesRevision` here, and the
    /// popover's content as `TranscriptRow.lookupAnchor` on the row that
    /// builds this view. The witness is `nonisolated` so the conformance needs
    /// no `@preconcurrency`: every compared property is an immutable Sendable
    /// value.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
            && lhs.annotation == rhs.annotation
            && lhs.surfaceFont == rhs.surfaceFont
            && lhs.annotationFont == rhs.annotationFont
            && lhs.furiganaFont == rhs.furiganaFont
            && lhs.annotationColor == rhs.annotationColor
            && lhs.surfaceItalic == rhs.surfaceItalic
            && lhs.reservesAnnotationLine == rhs.reservesAnnotationLine
            && lhs.cursorMode == rhs.cursorMode
            && lhs.favoritesRevision == rhs.favoritesRevision
    }

    /// One rendered child on the legacy path. Internal (not private) so the
    /// favorite run-break rule is unit-testable without a rendered view.
    enum DisplayUnit: Equatable {
        case plain(String, isFavorite: Bool)
        case annotated(surface: String, note: String, isFavorite: Bool)

        var isAnnotated: Bool {
            guard case .annotated = self else { return false }
            return true
        }

        /// Whether this unit carries the favorite color. The path gate reads it
        /// alongside `isAnnotated`: a sentence whose only marked unit is a
        /// favorite still has to render as units to show the color.
        var isFavorite: Bool {
            switch self {
            case let .plain(_, isFavorite): isFavorite
            case let .annotated(_, _, isFavorite): isFavorite
            }
        }
    }

    /// Pins FlowLayout's size cache: annotation and cursor mode change
    /// child structure (the dictionary path drops plain-run folding), the
    /// italic flag changes child structure, the fonts change child sizes,
    /// the text changes surfaces, and the reservation adds or drops the
    /// spacer line above plain/annotated units. Colors paint only, so they
    /// are excluded.
    var fingerprint: String {
        "\(annotation)-\(cursorMode)-\(reservesAnnotationLine)-\(dictionaryLookupActive)-"
            + "\(surfaceItalic)-\(surfaceFont.hashValue)-\(noteFont.hashValue)-\(text)"
    }

    /// Pure folding rule for the legacy path: consecutive runs without a
    /// distinct reading merge into one `.plain` child (whitespace and
    /// punctuation arrive as separate segments from the annotator).
    ///
    /// The favorite flag is resolved *before* folding, and a run only folds
    /// when none of its segments is a favorite. That guard is load-bearing,
    /// not vestigial: two real cases drop a starred segment into an otherwise
    /// plain run — a reading-less kanji in romaji mode, whose reading equals
    /// its surface, and every kana-only surface in furigana mode, whose
    /// furigana is nil unless the surface contains kanji (コーヒー,
    /// ゆっくり). Folding them would leave the commonest favorites silently
    /// uncolored in exactly the mode a reader is most likely to use.
    static func displayUnits(
        for segments: [ReadingSegment], annotation: ReadingAnnotation,
        isFavorite: ((ReadingSegment) -> Bool)?
    ) -> [DisplayUnit] {
        var units: [DisplayUnit] = []
        units.reserveCapacity(segments.count)
        for segment in segments {
            let note = reading(for: segment, annotation: annotation)
            let favorite = isFavorite?(segment) == true
            if let note, note != segment.surface {
                units.append(.annotated(
                    surface: segment.surface, note: note, isFavorite: favorite
                ))
            } else if case let .plain(run, runIsFavorite)? = units.last, !runIsFavorite, !favorite {
                units[units.count - 1] = .plain(run + segment.surface, isFavorite: false)
            } else {
                units.append(.plain(segment.surface, isFavorite: favorite))
            }
        }
        return units
    }

    /// The segments this body renders, folded.
    private var displayUnits: [DisplayUnit] {
        guard let segments = ReadingAnnotator.segments(for: text, caching: cachesSegments) else {
            return []
        }
        return Self.displayUnits(
            for: segments, annotation: annotation, isFavorite: isFavoriteSegment
        )
    }

    private static func reading(
        for segment: ReadingSegment, annotation: ReadingAnnotation
    ) -> String? {
        annotation == .furigana ? segment.furigana : segment.romaji
    }

    /// The annotation's font per mode: furigana honors `furiganaFont`, the
    /// other modes use `annotationFont`.
    private var noteFont: Font {
        annotation == .furigana ? (furiganaFont ?? annotationFont) : annotationFont
    }

    /// Invisible spacer matching one annotation line; reserves the furigana
    /// slot so surfaces across modes and units share one vertical position.
    private var reservedAnnotationLine: some View {
        AnnotationLineSpacer(font: noteFont)
    }

    @ViewBuilder
    private func unitView(_ unit: DisplayUnit) -> some View {
        switch unit {
        case let .plain(run, isFavorite):
            plainUnit(run, isFavorite: isFavorite, action: copyAction(run))
        case let .annotated(surface, note, isFavorite):
            annotatedUnit(surface, note: note, isFavorite: isFavorite, action: copyAction(surface))
        }
    }

    private func annotatedUnit(
        _ surface: String, note: String, isFavorite: Bool, action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 0) {
            // Furigana mode already renders the annotation line above
            // the surface; the reservation is only needed for modes
            // that would otherwise start the surface at the top.
            if annotation != .furigana, reservesAnnotationLine {
                reservedAnnotationLine
            }
            if annotation == .furigana {
                Text(verbatim: note)
                    .font(noteFont)
                    .foregroundStyle(annotationColor)
                    .lineLimit(1)
                    .textSelection(.disabled)
                hoverableSurface(surface, isFavorite: isFavorite, action: action)
            } else {
                hoverableSurface(surface, isFavorite: isFavorite, action: action)
                Text(verbatim: note)
                    .font(noteFont)
                    .foregroundStyle(annotationColor)
                    .lineLimit(1)
                    .textSelection(.disabled)
            }
        }
    }

    /// Furigana sits above the surface, and the flow layout top-aligns its
    /// children — so an unannotated run must reserve an invisible annotation
    /// line to keep its surface on the same baseline as annotated words.
    /// (Romaji sits below the surface, where top alignment already works —
    /// unless `reservesAnnotationLine` asks for the line above as well, to
    /// pin the surface to the same height across all annotation modes.)
    @ViewBuilder
    private func plainUnit(
        _ surface: String, isFavorite: Bool, action: (() -> Void)?
    ) -> some View {
        if annotation == .furigana || reservesAnnotationLine {
            VStack(spacing: 0) {
                reservedAnnotationLine
                hoverableSurface(surface, isFavorite: isFavorite, action: action)
            }
        } else {
            hoverableSurface(surface, isFavorite: isFavorite, action: action)
        }
    }
}

/// Invisible spacer matching one annotation line; reserves the annotation
/// slot so surfaces share one vertical position across modes and units.
struct AnnotationLineSpacer: View {
    let font: Font

    var body: some View {
        Color.clear.frame(width: 0, height: AnnotationLineMetrics.height(for: font))
    }
}

/// Height SwiftUI gives a single note line for a font, measured once per font
/// and cached. Reserved lines used to lay out a `Text(" ")` per unit to get
/// this height; a zero-size frame reproduces it exactly with no glyph layout.
/// The height is measured with an offscreen hosting view rather than AppKit
/// font metrics, which disagree with SwiftUI's own line height (e.g. 11pt
/// monospaced: AppKit 13, SwiftUI 14).
@MainActor
private enum AnnotationLineMetrics {
    private static var heights: [Font: CGFloat] = [:]

    static func height(for font: Font) -> CGFloat {
        if let cached = heights[font] {
            return cached
        }
        let probe = NSHostingView(rootView: NoteLineProbe(font: font))
        probe.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        probe.layoutSubtreeIfNeeded()
        let height = probe.fittingSize.height
        heights[font] = height
        return height
    }

    private struct NoteLineProbe: View {
        let font: Font

        var body: some View {
            Text(verbatim: " ")
                .font(font)
                .lineLimit(1)
        }
    }
}
