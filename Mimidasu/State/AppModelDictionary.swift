import Foundation

/// One preparable dictionary artifact: its async builder and the log line a
/// failure of it is reported with.
private struct DictionaryArtifact {
    let prepare: () async throws -> URL
    let log: String
}

/// Dictionary preparation surface of `AppModel` (file split for the lint
/// gate): the first-launch kick-off of both artifacts and the session-start
/// gate that blocks on either missing one.
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
