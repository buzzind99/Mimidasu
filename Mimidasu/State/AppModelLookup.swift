import Foundation

// LookupContent lives in Dictionary/LookupContent.swift; tap resolution,
// Display/Also/Related classification, favorite-first promotion, and pager
// clamping live in Dictionary/LookupDisplay.swift — this file is wiring
// only: build the request, guard the generation on landing, route the
// outcome to card/popover/warning/toast.

/// The app's single dictionary popover anchor: which surface owns it, the
/// content it shows, and the paged entry index (a candidate can match
/// several entries — the pager walks them surface-writing match first,
/// then reading-match, then common-first, then `ent_seq`).
struct SelectedLookup: Equatable, Identifiable, Sendable {
    /// Where the popover is anchored. One popover app-wide: only the
    /// surface whose source matches presents it. The transcript anchor is
    /// the tapped word itself — `tokenIndex` is the segment index into the
    /// annotator segments the row rendered from — so the arrow points at
    /// the word, not the row.
    enum Source: Equatable, Hashable, Sendable {
        case transcript(sentenceIndex: Int, tokenIndex: Int)
        case liveStrip
    }

    var content: LookupContent
    var source: Source
    var entryIndex: Int

    /// Presentation identity. Popover presentation is keyed on `source`
    /// alone (a same-source retap swaps the content in place); the id
    /// distinguishes results for debugging and tests, and stays stable
    /// across entry paging (a page turn updates contents, not identity).
    var id: String {
        let token: String = switch content {
        case let .found(result, _, _): result.matched
        case let .notFound(surface, _): "not-found:\(surface)"
        }
        return "\(source)-\(token)"
    }
}

extension SelectedLookup {
    /// The popover item a given surface presents — only the surface whose
    /// anchor matches `source` shows the popover; every other surface sees
    /// nothing. Pure helper.
    func popoverItem(for source: Source) -> SelectedLookup? {
        self.source == source ? self : nil
    }
}

/// The pinned sidebar DICTIONARY card content: the last lookup of the
/// session — hit or not-found — with the paged entry index. Persists after
/// the popover dismisses; cleared on session clear.
struct PinnedLookup: Equatable, Sendable {
    var content: LookupContent
    var entryIndex: Int
}

extension AppModel {

    /// The tap display module bound to the injected engine. Stateless and
    /// cheap — a computed holder, so tests inject `jmDictLookup` and the
    /// display follows with no init churn.
    private var lookupDisplay: LookupDisplay {
        LookupDisplay(lookup: jmDictLookup)
    }

    // MARK: - Tap entry point

    /// UI entry for a dictionary-mode tap: re-resolves the segments for the
    /// tapped sentence at tap time (cached for unchanged text) and runs the
    /// lookup on a background task. The payload's render-time index crosses
    /// raw — the module re-anchors it single-place at resolve time. UI
    /// state is only ever touched back on the main actor.
    func handleLookupTap(_ token: LookupToken, source: SelectedLookup.Source) {
        let segments = ReadingAnnotator.segments(for: token.sentenceText)?
            .map { segment in LookupSegment(
                surface: segment.surface,
                lemma: segment.lemma,
                reading: segment.kanaReading
            ) }
        lookupGeneration &+= 1
        let generation = lookupGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await runLookup(
                segments: segments,
                tappedAt: token.tokenIndex,
                sentenceText: token.sentenceText,
                surface: token.surface,
                source: source,
                generation: generation
            )
        }
    }

    /// Builds the tap request, resolves it through the display module
    /// off-main, drops stale generations, and routes the effect. Internal
    /// and fully parameterized so tests await it directly over an injected
    /// fixture engine (`generation` nil skips the staleness check).
    func runLookup(
        segments: [LookupSegment]?, tappedAt: Int, sentenceText: String,
        surface: String, source: SelectedLookup.Source, generation: Int? = nil
    ) async {
        let display = lookupDisplay
        let keys = favorites.favoriteKeys
        let effect = await display.resolve(
            TapLookupRequest(
                segments: segments, tappedAt: tappedAt,
                sentenceText: sentenceText, surface: surface
            ),
            favorites: keys
        )
        if let generation, generation != lookupGeneration {
            return
        }
        applyEffect(effect, source: source)
    }

    /// Routes a resolved tap: a show selects + pins (popover anchor and
    /// sidebar card update together); a no-hit posts the amber warning
    /// pill; an infrastructure fault posts the `dictionaryLookup` toast
    /// (never the pill); a cancellation applies nothing at all.
    /// Internal so wiring tests feed canned effects.
    /// Caller must have passed the generation check — direct calls bypass
    /// staleness by construction; the production path guards in runLookup.
    func applyEffect(_ effect: TapLookupEffect, source: SelectedLookup.Source) {
        switch effect {
        case let .show(content, entryIndex):
            presentLookup(content: content, source: source, entryIndex: entryIndex)
        case let .warnNoHit(surface):
            notices.post(
                message: "No dictionary entry for \"\(surface)\"", tone: .warning
            )
        case let .fault(fault):
            toasts.post(
                key: ToastKey.dictionaryLookup, style: .yellowAuto,
                title: "Dictionary lookup failed", body: fault.localizedDescription
            )
        case .cancelled:
            break
        }
    }

    /// Presents a resolved lookup: pins the sidebar card and, when a source
    /// is supplied (a popover is up), anchors the popover to the same content.
    /// Both start at the effect's entry, keeping the two surfaces from
    /// drifting apart.
    private func presentLookup(
        content: LookupContent, source: SelectedLookup.Source?, entryIndex: Int = 0
    ) {
        pinnedLookup = PinnedLookup(content: content, entryIndex: entryIndex)
        if let source {
            selectedLookup = SelectedLookup(
                content: content, source: source, entryIndex: entryIndex
            )
        }
    }

    // MARK: - Popover lifecycle

    /// The popover's set-nil path (dismiss, Escape): clears the selection
    /// only when the dismissing surface owns the anchor, so a stale binding
    /// from a virtualized-off-screen row can never clobber a newer
    /// selection. Pinned state persists.
    func dismissLookupPopover(source: SelectedLookup.Source) {
        if selectedLookup?.source == source {
            selectedLookup = nil
        }
    }

    // MARK: - Fallback pills

    /// Selects a fallback pill — an "also:" hit on a found card, or a
    /// "related:" suggestion on a not-found one: the pinned card and the
    /// live popover (when one is up) switch to that result as found, and
    /// the pill row recomputes from the retained results relative to the
    /// new selection — no new query runs. Re-promotion runs through the
    /// display module against the favorites snapshot. Re-selecting the
    /// already-shown result keeps its origin while still re-applying the
    /// latest favorites.
    func selectAlsoPill(_ result: LookupResult) {
        guard let pinned = pinnedLookup else { return }
        let source = selectedLookup?.source
        let content = lookupDisplay.promote(
            result, in: pinned.content, favorites: favorites.favoriteKeys
        )
        // A foreign choice promotes to the content unchanged — presenting
        // it would only reset the pager to the default entry.
        guard content != pinned.content else { return }
        presentLookup(content: content, source: source)
    }

    // MARK: - Entry pager

    /// Turns the `◀ i/N ▶` pager to `index` (clamped by the module):
    /// popover and pinned card page together, both showing the selected
    /// entry. A not-found pin has no entries; the pager is inert.
    func stepLookupEntry(to index: Int) {
        let content = selectedLookup?.content ?? pinnedLookup?.content
        guard let clamped = lookupDisplay.steppedEntry(in: content, to: index) else { return }
        selectedLookup?.entryIndex = clamped
        pinnedLookup?.entryIndex = clamped
    }
}
