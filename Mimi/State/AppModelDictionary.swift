import Foundation

/// One preparable dictionary artifact: the resolve probe and its async builder.
private struct DictionaryArtifact {
    let resolve: () -> URL?
    let prepare: () async throws -> URL
}

/// Dictionary preparation surface of `AppModel` (file split for the lint
/// gate): the first-launch kick-off of both artifacts and the session-start
/// gate that blocks on either missing one.
extension AppModel {
    /// Kicks the first-launch dictionary preparations — the tokenizer
    /// dictionary (bundled `system.dic.zst` → decompressed dictionary, see
    /// `DictionaryStore`) and the JMDict lookup database
    /// (`jmdict-<tag>.sqlite.zst` → versioned SQLite file) — in the
    /// background so ruby annotations and lookups come up soon after
    /// startup. The two artifacts are covered independently: one resolving
    /// does not excuse the other. Purely opportunistic: until it succeeds
    /// (or if it never does) text renders unannotated and lookups fail
    /// soft, so failures are logged only and retried on the next launch.
    /// The `resolve`/`prepare` pairs are injectable for tests; the defaults
    /// drive the real store.
    func prepareDictionaryIfNeeded(
        resolve: @escaping () -> URL? = { DictionaryStore.resolve() },
        resolveJMDict: @escaping () -> URL? = { DictionaryStore.resolveJMDict() },
        prepare: @escaping () async throws -> URL = DictionaryStore.shared.prepare,
        prepareJMDict: @escaping () async throws -> URL = DictionaryStore.shared.prepareJMDict
    ) {
        let artifacts: [(DictionaryArtifact, String)] = [
            (
                DictionaryArtifact(resolve: resolve, prepare: prepare),
                "[dictionary] first-launch build failed; text stays unannotated"
            ),
            (
                DictionaryArtifact(resolve: resolveJMDict, prepare: prepareJMDict),
                "[jmdict] first-launch build failed; lookups stay unavailable"
            )
        ]
        for (artifact, log) in artifacts where artifact.resolve() == nil {
            Task {
                do {
                    _ = try await artifact.prepare()
                } catch {
                    print("\(log): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Session-start gate: a session must never run while furigana or
    /// dictionary lookups are silently missing, so either missing database
    /// is built before capture begins. The launch-time kick
    /// (`prepareDictionaryIfNeeded`, above) usually finishes the builds
    /// first; this coalesces behind in-flight builds on the store's queue
    /// and only blocks when none is running. A failed build throws so the
    /// start fails visibly in the status bar (pressing Start again
    /// retries). The `resolve`/`prepare` pairs are injectable for tests;
    /// the defaults drive the real store.
    func ensureDictionaryReady(
        resolve: @escaping () -> URL? = { DictionaryStore.resolve() },
        resolveJMDict: @escaping () -> URL? = { DictionaryStore.resolveJMDict() },
        prepare: @escaping () async throws -> URL = DictionaryStore.shared.prepare,
        prepareJMDict: @escaping () async throws -> URL = DictionaryStore.shared.prepareJMDict
    ) async throws {
        let artifacts: [DictionaryArtifact] = [
            DictionaryArtifact(resolve: resolve, prepare: prepare),
            DictionaryArtifact(resolve: resolveJMDict, prepare: prepareJMDict)
        ]
        let missing = artifacts.filter { artifact in artifact.resolve() == nil }
        guard !missing.isEmpty else { return }
        isPreparingDictionary = true
        defer { isPreparingDictionary = false }
        for artifact in missing {
            _ = try await artifact.prepare()
        }
    }
}
