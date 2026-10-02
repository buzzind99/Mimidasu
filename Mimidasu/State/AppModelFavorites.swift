import Foundation

/// Favorites as the UI sees them: the star behind every dictionary header,
/// and the matcher the transcript hands to each rendered segment. A thin
/// forwarder over `FavoritesStore` — the data, the cap, and the matching
/// rules live there; this file only owns the *outcomes* (which notice or
/// toast each result deserves, and whether a press needs asking about).
extension AppModel {
    /// Removes `headword` once its confirmation has been answered. Silent like
    /// every other removal — the alert already said what happened, and a pill
    /// would only cover the transcript.
    func confirmFavoriteRemoval(headword: String) {
        favorites.remove(headword: headword)
    }

    /// Stars the displayed entry's headword. An entry that is already a
    /// favorite does not un-star on this press: it reports
    /// `.pendingRemoval(headword)`, changes nothing, and the host raises the
    /// confirmation — in its own state, so only the pressed host's alert
    /// shows. `DictionaryContent.headword` is already `keb ?? reb`, so
    /// homographs sharing a `keb` share one row and one star state: they are
    /// the same word.
    @discardableResult
    func toggleFavorite(_ entry: JMDictEntry) -> FavoriteToggle {
        guard let headword = DictionaryContent.headword(of: entry) else { return .failed }
        if favorites.isFavorite(headword: headword) {
            return .pendingRemoval(headword: headword)
        }
        let outcome = favorites.toggle(FavoriteWord(
            headword: headword,
            reading: entry.reb,
            romaji: entry.reb.flatMap(KanaRomaji.romaji(fromKana:)),
            addedAt: Int(Date.now.timeIntervalSince1970 * 1000)
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
            toasts.post(
                key: ToastKey.favorites, style: .redPersistent,
                title: "Favorites unavailable",
                body: "The favorites list could not be updated. Remove "
                    + "favorites.sqlite from Application Support to start over."
            )
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
        favorites.isFavorite(headword: DictionaryContent.headword(of: entry))
    }

    /// The per-segment probe the transcript, live strip, and HUD pass down.
    /// Built fresh per access so each render gets a stable closure value.
    var favoriteSegmentMatcher: (ReadingSegment) -> Bool {
        let store = favorites
        return { segment in store.matches(segment: segment) }
    }
}
