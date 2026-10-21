import Foundation

// The dictionary surface of `AppModel`: the tap lookup (popover anchor, pinned
// card, and the wiring behind them), the artifact preparation that gates a
// session start, and the starred words behind every dictionary header.
//
// **Seam rule:** a feature file that outgrows 600 **code** lines splits at the
// next feature boundary — never mid-feature, never because it grew more
// documentation.

// The tap-lookup surface of `AppModel`: the single dictionary popover
// anchor, the pinned card, and the wiring that builds the request, guards
// the generation on landing, and routes the outcome to the card, the
// popover, a warning, or a toast. The lookup content and its
// classification live in the dictionary layer, not here.

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
    /// tapped sentence at tap time (cached for unchanged text) and captures
    /// the favorites identity on the same synchronous hop, then runs the
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
        let identity = favorites.identity
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
                generation: generation,
                favoritesSnapshot: identity
            )
        }
    }

    /// Builds the tap request, resolves it through the display module
    /// off-main, drops stale generations, and routes the effect. Internal
    /// and fully parameterized so tests await it directly over an injected
    /// fixture engine (`generation` nil skips the staleness check).
    /// The favorites snapshot defaults to the current store so tests can
    /// omit it; the tap entry point passes its tap-time capture.
    func runLookup(
        segments: [LookupSegment]?, tappedAt: Int, sentenceText: String,
        surface: String, source: SelectedLookup.Source, generation: Int? = nil,
        favoritesSnapshot: FavoriteIdentity? = nil
    ) async {
        let display = lookupDisplay
        let identity = favoritesSnapshot ?? favorites.identity
        let effect = await display.resolve(
            TapLookupRequest(
                segments: segments, tappedAt: tappedAt,
                sentenceText: sentenceText, surface: surface
            ),
            favorites: identity
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
    /// Both start at the effect's entry, clamped through the module so a
    /// future caller can never pin an out-of-bounds page, keeping the two
    /// surfaces from drifting apart.
    private func presentLookup(
        content: LookupContent, source: SelectedLookup.Source?, entryIndex: Int = 0
    ) {
        let clamped = lookupDisplay.steppedEntry(in: content, to: entryIndex) ?? 0
        pinnedLookup = PinnedLookup(content: content, entryIndex: clamped)
        if let source {
            selectedLookup = SelectedLookup(
                content: content, source: source, entryIndex: clamped
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
            result, in: pinned.content, favorites: favorites.identity
        )
        // A foreign choice promotes to the content unchanged — presenting
        // it would only reset the pager to the default entry, while a
        // promoted move restarts the pager at the new display's first entry.
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

/// One preparable dictionary artifact: its async builder and the log line a
/// failure of it is reported with.
private struct DictionaryArtifact {
    let prepare: () async throws -> URL
    let log: String
}

/// Dictionary preparation surface of `AppModel`: the first-launch kick-off of
/// both artifacts and the session-start gate that blocks on either missing
/// one.
extension AppModel {
    /// Kicks the dictionary preparations — the tokenizer dictionary (bundled
    /// `system.dic.zst` → decompressed dictionary, see `DictionaryStore`) and
    /// the JMDict lookup database (`jmdict-<tag>.<rev>.sqlite.zst` → versioned
    /// SQLite file) — in the background so ruby annotations and lookups come up
    /// soon after startup.
    ///
    /// **Both artifacts, unconditionally.** Deciding here whether a build is
    /// needed is what broke it: the natural gate is "does the file resolve",
    /// but `resolveJMDict()` answers "does the file exist", not "is the file
    /// usable". A database promoted before the gloss index existed resolves, so
    /// it short-circuited every prepare, so the store's index-aware adoption
    /// check was never reached, so the index-less database was adopted forever
    /// — and with the `LIKE` scan deleted, every Latin gloss query returned
    /// zero rows with no error to show for it.
    ///
    /// So the check lives in exactly one place, `DictionaryStore.run`, which
    /// adopts a current database for the cost of a `fileExists` and two pragma
    /// reads and re-stages anything else. Calling it always is the cheap path.
    ///
    /// Purely opportunistic: until it succeeds (or if it never does) text
    /// renders unannotated and lookups fail soft, so failures are logged only
    /// and retried on the next launch. The builders are injectable for tests;
    /// the defaults drive the real store.
    func prepareDictionaries(
        prepare: @escaping () async throws -> URL = DictionaryStore.shared.prepare,
        prepareJMDict: @escaping () async throws -> URL = DictionaryStore.shared.prepareJMDict
    ) {
        let artifacts = [
            DictionaryArtifact(
                prepare: prepare,
                log: "[dictionary] first-launch build failed; text stays unannotated"
            ),
            DictionaryArtifact(
                prepare: prepareJMDict,
                log: "[jmdict] first-launch build failed; lookups stay unavailable"
            )
        ]
        for artifact in artifacts {
            Task {
                do {
                    _ = try await artifact.prepare()
                } catch {
                    print("\(artifact.log): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Session-start gate: a session must never run while furigana or
    /// dictionary lookups are silently missing, so both databases are confirmed
    /// usable before capture begins — adopted if current, built if not. The
    /// launch-time kick (`prepareDictionaries`, above) usually gets there
    /// first; this coalesces behind in-flight builds on the store's queue.
    /// A failed build throws so the start fails visibly in the status bar
    /// (pressing Start again retries). The builders are injectable for tests;
    /// the defaults drive the real store.
    func ensureDictionaryReady(
        prepare: @escaping () async throws -> URL = DictionaryStore.shared.prepare,
        prepareJMDict: @escaping () async throws -> URL = DictionaryStore.shared.prepareJMDict
    ) async throws {
        isPreparingDictionary = true
        defer { isPreparingDictionary = false }
        _ = try await prepare()
        _ = try await prepareJMDict()
    }
}

/// Favorites as the UI sees them: the star behind every dictionary header,
/// and the matcher the transcript hands to each rendered segment. A thin
/// forwarder over `FavoritesStore` — the data, the cap, and the matching
/// rules live there; this file only owns the *outcomes* (which notice or
/// toast each result deserves, and whether a press needs asking about).
extension AppModel {
    /// Removes `headword` once its confirmation has been answered. A removal
    /// that succeeds is silent — the alert already said what happened, and a
    /// pill would only cover the transcript. A removal the store could not
    /// perform is the opposite case: nothing changed on screen, so it reports
    /// itself the same way the add path does.
    func confirmFavoriteRemoval(headword: String) {
        if case .failed = favorites.remove(headword: headword) {
            postUnavailable()
        }
    }

    /// The one surface a broken store has. Persistent and red, because it is a
    /// fault rather than an outcome, and keyed so it replaces itself in place
    /// instead of stacking on every failed star press.
    private func postUnavailable() {
        toasts.post(
            key: ToastKey.favorites, style: .redPersistent,
            title: "Favorites unavailable",
            body: "The favorites list could not be updated. Remove "
                + "favorites.sqlite from Application Support to start over."
        )
    }

    /// Stars the displayed entry's headword — the entry every dictionary host
    /// has in hand. A thin forwarder to the headword form below, which is the
    /// one that owns the outcomes.
    @discardableResult
    func toggleFavorite(_ entry: JMDictEntry) -> FavoriteToggle {
        toggleFavorite(headword: FavoriteIdentity.headword(of: entry), reading: entry.reb)
    }

    /// Stars `headword`, read in `reading`. The one star press, and the only
    /// place its outcome is decided — a notice for an add or a refusal, a toast
    /// for a broken store — so the popover, the sidebar card, and a dictionary
    /// search row cannot disagree about what a press reports.
    ///
    /// An entry that is already a favorite does not un-star on this press: it
    /// reports `.pendingRemoval(headword)`, changes nothing, and the window
    /// raises the confirmation from its single slot — hosts only forward the
    /// headword, so the popover and the card, mounted together for one lookup,
    /// cannot both present.
    ///
    /// Identity is the headword alone, and every caller derives it the same
    /// way (kanji writing when present, else the reading — an empty spelling
    /// counts as absent), so homographs sharing a `keb` share one row and one
    /// star state: they are the same word.
    @discardableResult
    func toggleFavorite(headword: String?, reading: String?) -> FavoriteToggle {
        // Every JMDict row carries at least one `reb`, so a nil or empty
        // headword only arrives from a hand-built entry; it stays silent
        // rather than blaming a store that is fine, and names nothing the
        // user could act on.
        guard let headword, !headword.isEmpty else { return .failed }
        if favorites.isFavorite(headword: headword) {
            return .pendingRemoval(headword: headword)
        }
        let outcome = favorites.toggle(FavoriteWord.starred(
            headword: headword, reading: reading
        ))
        switch outcome {
        case .added:
            notices.post(message: "Added to favorites", tone: .confirm)
        case .limitReached:
            notices.post(
                message: "Favorites are full (\(FavoritesStore.limit)) — "
                    + "remove one to add another",
                tone: .warning
            )
        case .failed:
            postUnavailable()
        default:
            // `.removed` and `.pendingRemoval` cannot arrive: the guard above
            // returns for an already-starred word, and `FavoritesStore.toggle`
            // reports `.removed` exactly when `isFavorite` is true. Both
            // would be silent anyway.
            break
        }
        return outcome
    }

    /// Membership of the displayed entry — derived from the entry on every
    /// render, never carried over from a previous selection. A related-pill
    /// promotion repins both hosts, and a cached value would show the
    /// pre-promotion entry's membership for as long as it survived.
    func isFavorite(_ entry: JMDictEntry) -> Bool {
        favorites.identity.isFavorite(entry)
    }

    /// Whether a fallback pill leads with a favorited entry — the pill
    /// star's probe. Promotion already moved an eligible favorite to the
    /// front, so a favorited lead is the pill's starred word; a favorite
    /// matched through another spelling stays behind the lead.
    func isFavoriteLead(_ result: LookupResult) -> Bool {
        favorites.identity.leads(result)
    }

    /// The per-segment probe the transcript, live strip, and HUD pass down.
    /// A fresh closure per access: identity is meaningless here, which is why
    /// membership changes travel as `favorites.revision` instead.
    var favoriteSegmentMatcher: (ReadingSegment) -> Bool {
        let store = favorites
        return { segment in store.matches(segment: segment) }
    }
}
