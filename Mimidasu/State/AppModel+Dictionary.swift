import Foundation

// The dictionary surface of `AppModel`: the tap-lookup façade over
// `TapLookupSession`, the artifact preparation that gates a session start, and
// the starred words behind every dictionary header.
//
// Taps, dismissal, fallback selection, and pager steps forward to `tapLookup`,
// the one owner of lookup state. `lookupPresentation` is the single value both
// hosts read; no host keeps a second copy.
//
// **Seam rule:** a feature file that outgrows 600 **code** lines splits at the
// next feature boundary — never mid-feature, never because it grew more
// documentation.

extension AppModel {

    // MARK: - Presentation

    /// The one lookup both dictionary hosts read: content, paged entry, and
    /// the anchor whose popover is up (nil after dismissal). The session owns
    /// it; this is a read-only view.
    var lookupPresentation: LookupPresentation? {
        tapLookup.presentation
    }

    // MARK: - Tap entry point

    /// UI entry for a dictionary tap: forwards the tap-time request and the
    /// favorites snapshot to the session, which owns generation, resolution,
    /// and landing. The returned task lets callers await the landing.
    @discardableResult
    func handleLookupTap(
        _ request: TapLookupRequest, anchor: LookupAnchor
    ) -> Task<Void, Never> {
        tapLookup.tap(request, anchor: anchor, favorites: favorites.snapshot.identity)
    }

    // MARK: - Popover lifecycle

    /// The popover's set-nil path (dismiss, Escape): the session clears the
    /// anchor only when the dismissing surface owns it, so a stale binding
    /// from a virtualized-off-screen row cannot clobber a newer selection.
    /// Pinned state persists.
    func dismissLookupPopover(from anchor: LookupAnchor) {
        tapLookup.dismissPopover(from: anchor)
    }

    // MARK: - Fallback pills

    /// Selects a fallback pill — an "also:" hit on a found card, or a
    /// "related:" suggestion on a not-found one: the session switches the
    /// display to that result as found, recomputes the pill row from the
    /// retained results, re-promotes favorites, resets the pager, and keeps
    /// the current anchor. No new query runs.
    func selectAlsoPill(_ result: LookupResult) {
        tapLookup.selectFallback(result, favorites: favorites.snapshot.identity)
    }

    // MARK: - Entry pager

    /// Turns the `◀ i/N ▶` pager to `index` (clamped by the session):
    /// popover and pinned card page together. A not-found pin has no
    /// entries; the pager is inert.
    func stepLookupEntry(to index: Int) {
        tapLookup.stepEntry(to: index)
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
    /// it short-circuited every prepare, so the adoption verdict was never
    /// reached, so the index-less database was adopted forever — and with the
    /// `LIKE` scan deleted, every Latin gloss query returned zero rows with no
    /// error to show for it.
    ///
    /// So the verdict lives in `PreparedJMDict.isAdoptable`, and
    /// `DictionaryStore.run` asks it unconditionally: a current database is
    /// adopted for the cost of a `fileExists` and two pragma reads, anything
    /// else re-stages. Calling it always is the cheap path.
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
        if favorites.snapshot.identity.isFavorite(headword: headword) {
            return .pendingRemoval(headword: headword)
        }
        let outcome = favorites.add(FavoriteWord.starred(
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
            // `.unchanged`, `.removed`, and `.pendingRemoval` cannot arrive:
            // the guard above returns for an already-starred word, `add`
            // answers that same membership check, and nothing here deletes.
            // All would be silent anyway.
            break
        }
        return outcome
    }

    /// Membership of the displayed entry — derived from the entry on every
    /// render, never carried over from a previous selection. A related-pill
    /// promotion repins both hosts, and a cached value would show the
    /// pre-promotion entry's membership for as long as it survived.
    func isFavorite(_ entry: JMDictEntry) -> Bool {
        favorites.snapshot.identity.isFavorite(entry)
    }

    /// Whether a fallback pill leads with a favorited entry — the pill
    /// star's probe. Promotion already moved an eligible favorite to the
    /// front, so a favorited lead is the pill's starred word; a favorite
    /// matched through another spelling stays behind the lead.
    func isFavoriteLead(_ result: LookupResult) -> Bool {
        favorites.snapshot.identity.leads(result)
    }

    /// The per-segment probe the transcript, live strip, and HUD pass down.
    /// A fresh closure per access: the closure itself carries no observable
    /// state, which is why membership changes travel as `favorites.snapshot`
    /// instead.
    var favoriteSegmentMatcher: (ReadingSegment) -> Bool {
        let store = favorites
        return { segment in store.matches(segment: segment) }
    }
}
