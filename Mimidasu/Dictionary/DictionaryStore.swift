import Foundation
import Synchronization

/// Manages the local dictionary files the annotation and lookup layers read.
/// Both artifacts ship compressed in the app bundle and are decompressed once
/// through the runtime's prepare FFI on first launch — no network, no build
/// step. The tokenizer dictionary (`system.dic.zst` → `ipadic.dic`) is
/// unversioned; the JMDict lookup database (`jmdict-<tag>.<rev>.sqlite.zst` →
/// `jmdict-<tag>.<rev>.sqlite`) carries the pin tag + build revision in its
/// filename, which is the
/// staleness key: an app update shipping a new pin stages a *new* file and
/// stale ones are removed after the next successful promote.
///
/// Sendable by construction: `phases` is the only mutable state, wrapped in
/// a `Mutex`, and every access happens on the serial `queue` too (see the
/// `Phase` comment below — the queue is the coalescing point, the mutex
/// makes the store compiler-checked Sendable).
final class DictionaryStore: Sendable {
    static let shared = DictionaryStore()

    enum DictionaryStoreError: LocalizedError, Equatable {
        case libraryUnavailable
        case bundledDictionaryMissing
        case bundledJMDictMissing
        case prepareFailed(returnCode: Int32)
        case smokeTestFailed(reason: String)

        var errorDescription: String? {
            switch self {
            case .libraryUnavailable:
                "Dictionary runtime library not found; text renders unannotated."
            case .bundledDictionaryMissing:
                "Bundled system.dic.zst not found in the app bundle."
            case .bundledJMDictMissing:
                "Bundled \(JMDictPin.bundledFileName) not found in the app bundle."
            case let .prepareFailed(returnCode):
                "Dictionary decompression failed (return code \(returnCode))."
            case let .smokeTestFailed(reason):
                "Dictionary failed its smoke query: \(reason)."
            }
        }
    }

    // MARK: - Locations

    static let dictionaryFileName = "ipadic.dic"

    #if DEBUG
        /// Anchors the scripts' checkout-relative artifacts (`local/`,
        /// `build/`, `models/`) to the repo root. The process working
        /// directory is not the checkout under `xcodebuild test`, so plain
        /// CWD-relative fallbacks silently miss there; `#filePath` is the
        /// compiled source path, which for a debug checkout lives inside the
        /// repo. Release never consults this — it sees app-bundle paths only.
        private static let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Dictionary/
            .deletingLastPathComponent() // Mimidasu/
            .deletingLastPathComponent() // checkout root

        static func debugRepoURL(_ checkoutRelativePath: String) -> URL {
            repoRoot.appendingPathComponent(checkoutRelativePath)
        }
    #endif

    /// Where prepared artifacts land. Debug checkouts keep everything inside
    /// the repo's gitignored `build/` — tests and dev runs never write to the
    /// user's home directory; release builds use the per-user Application
    /// Support location.
    static var defaultDestinationDirectory: URL {
        #if DEBUG
            debugRepoURL("build/prepared/dictionaries")
        #else
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return base.appendingPathComponent("Mimidasu/dictionaries", isDirectory: true)
        #endif
    }

    static var defaultDictionaryURL: URL {
        defaultDestinationDirectory.appendingPathComponent(dictionaryFileName)
    }

    /// The prepared JMDict database. The versioned filename comes straight
    /// from the pin constants (`JMDictPin.preparedFileName`) — the same
    /// constants `scripts/build_dictionary.sh` asserts against, so the two can
    /// never silently drift.
    static var defaultJMDictURL: URL {
        defaultDestinationDirectory.appendingPathComponent(JMDictPin.preparedFileName)
    }

    /// The bundled compressed tokenizer dictionary. Release builds look in
    /// the app bundle only; debug checkouts fall back to the copy fetched by
    /// `scripts/build_tokenizer.sh` under `local/dictionaries/` (anchored to
    /// the checkout root) so first-launch can be exercised before bundling
    /// lands.
    static var defaultBundledSource: URL? {
        bundledOrDebug(
            resource: "system", ext: "dic.zst",
            debugPath: "local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst"
        )
    }

    /// The bundled compressed JMDict artifact, same split as
    /// `defaultBundledSource` but from `scripts/build_dictionary.sh`'s output.
    static var defaultBundledJMDictSource: URL? {
        bundledOrDebug(
            resource: JMDictPin.preparedFileName, ext: "zst",
            debugPath: "local/dictionaries/\(JMDictPin.bundledFileName)"
        )
    }

    /// Bundled-resource lookup with the shared debug-checkout fallback:
    /// release builds see the app bundle only, debug checkouts fall back to
    /// the copy the build scripts leave under `local/dictionaries/`, anchored
    /// to the checkout root (see `repoRoot`).
    private static func bundledOrDebug(
        resource: String, ext: String, debugPath: String
    ) -> URL? {
        if let bundled = Bundle.main.url(forResource: resource, withExtension: ext) {
            return bundled
        }
        #if DEBUG
            return debugRepoURL(debugPath)
        #else
            return nil
        #endif
    }

    /// The prepared dictionary, or nil when it still needs preparing.
    /// Resolution order: `MIMIDASU_DICT` env override (debug), the Application
    /// Support location, the dev-checkout `models/ipadic.dic` (debug —
    /// `models/` is gitignored). An existing dictionary always wins so
    /// prepare() never re-prepares.
    static func resolve() -> URL? {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            fileExists: { url in FileManager.default.fileExists(atPath: url.path) }
        )
    }

    /// Injectable core of `resolve()`: first candidate whose existence check
    /// passes; nil when none exist.
    static func resolve(environment: [String: String], fileExists: (URL) -> Bool) -> URL? {
        resolve(
            environmentKey: "MIMIDASU_DICT", defaultURL: defaultDictionaryURL,
            debugCheckoutPath: "models/\(dictionaryFileName)",
            environment: environment, fileExists: fileExists
        )
    }

    /// The prepared JMDict database, or nil when it still needs preparing.
    /// Same resolution order as `resolve()` but keyed on `MIMIDASU_JMDICT`, the
    /// versioned filename, and the `build/` intermediate the JMDict build
    /// script leaves in debug checkouts.
    static func resolveJMDict() -> URL? {
        resolveJMDict(
            environment: ProcessInfo.processInfo.environment,
            fileExists: { url in FileManager.default.fileExists(atPath: url.path) }
        )
    }

    /// Injectable core of `resolveJMDict()`.
    static func resolveJMDict(environment: [String: String], fileExists: (URL) -> Bool) -> URL? {
        resolve(
            environmentKey: "MIMIDASU_JMDICT", defaultURL: defaultJMDictURL,
            debugCheckoutPath: JMDictPin.debugCheckoutPath,
            environment: environment, fileExists: fileExists
        )
    }

    private static func resolve(
        environmentKey: String, defaultURL: URL, debugCheckoutPath: String,
        environment: [String: String], fileExists: (URL) -> Bool
    ) -> URL? {
        var candidates: [URL] = []
        #if DEBUG
            if let override = environment[environmentKey], !override.isEmpty {
                candidates.append(URL(fileURLWithPath: override))
            }
        #endif
        candidates.append(defaultURL)
        #if DEBUG
            candidates.append(debugRepoURL(debugCheckoutPath))
        #endif
        return candidates.first(where: fileExists)
    }

    // MARK: - Prepare

    /// Word certain to tokenize with a reading in any IPADIC build and carry
    /// a JMDict entry in any pin; both smoke queries require it to answer.
    private static let smokeWord = "学生"

    /// Queue-confined lifecycle, one phase per artifact. There is no
    /// `.preparing` state: every access happens on the serial queue, so
    /// concurrent prepare() calls simply line up behind the in-flight
    /// decompression and observe its outcome — that *is* the coalescing.
    private enum Phase {
        case idle
        case done(URL)
    }

    private struct Phases {
        var ipadic: Phase = .idle
        var jmDict: Phase = .idle
    }

    private let queue = DispatchQueue(label: "mimidasu.DictionaryStore", qos: .utility)
    private let bundledSource: URL?
    private let bundledJMDictSource: URL?
    private let destinationDirectory: URL
    private let ffi: DictionaryFFI?
    private let phases = Mutex(Phases())

    /// `ffi` and the locations are injectable for tests; defaults resolve the
    /// real runtime and locations. Loading the library at init is cheap
    /// (dlopen refcounts) and keeps prepare() free of lazy-binding races.
    init(
        bundledSource: URL? = DictionaryStore.defaultBundledSource,
        bundledJMDictSource: URL? = DictionaryStore.defaultBundledJMDictSource,
        destinationDirectory: URL = DictionaryStore.defaultDestinationDirectory,
        ffi: DictionaryFFI? = DictionaryFFI.load()
    ) {
        self.bundledSource = bundledSource
        self.bundledJMDictSource = bundledJMDictSource
        self.destinationDirectory = destinationDirectory
        self.ffi = ffi
    }

    /// Decompresses the bundled model if the dictionary does not exist yet;
    /// no-op afterwards. Concurrent callers coalesce on the single
    /// decompression — later callers suspend behind the in-flight work on the
    /// store's serial queue and observe its outcome. Throws when the artifact
    /// is missing, the runtime library is unavailable, or the decompress
    /// fails — callers silently degrade to plain text and may retry (next
    /// launch or a later call).
    func prepare() async throws -> URL {
        try await run(.tokenizer)
    }

    /// JMDict counterpart of `prepare()`: decompresses the bundled
    /// `jmdict-<tag>.<rev>.sqlite.zst` into the versioned destination, smoke-queries
    /// it through the JMDict lookup engine, and promotes it into place. The
    /// versioned filename is the staleness key — a new pin stages a new file
    /// and stale `jmdict-*.sqlite` artifacts from earlier pins are removed
    /// after a successful promote. Same coalescing: concurrent callers line
    /// up on the store's serial queue.
    func prepareJMDict() async throws -> URL {
        try await run(.jmDict)
    }

    /// One prepared artifact: its phase slot, destination filename, bundled
    /// source, and smoke check. Drives the shared prepare pipeline so the two
    /// artifacts differ only in these values.
    private enum Artifact: Equatable {
        case tokenizer
        case jmDict

        var destinationFileName: String {
            switch self {
            case .tokenizer: DictionaryStore.dictionaryFileName
            case .jmDict: JMDictPin.preparedFileName
            }
        }

        var missingSourceError: DictionaryStoreError {
            switch self {
            case .tokenizer: .bundledDictionaryMissing
            case .jmDict: .bundledJMDictMissing
            }
        }

        var phaseKeyPath: WritableKeyPath<Phases, Phase> {
            switch self {
            case .tokenizer: \.ipadic
            case .jmDict: \.jmDict
            }
        }

        var sourceKeyPath: KeyPath<DictionaryStore, URL?> {
            switch self {
            case .tokenizer: \.bundledSource
            case .jmDict: \.bundledJMDictSource
            }
        }
    }

    /// Dispatches onto the serial queue and awaits the outcome. Coalesces
    /// concurrent callers behind the phase check: a prepared artifact (done
    /// phase, or an earlier launch's file) is adopted; otherwise it is staged
    /// and promoted. A failed prepare resets the phase so a later call
    /// retries.
    private func run(_ artifact: Artifact) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let phase = self.phases.withLock { current in
                    current[keyPath: artifact.phaseKeyPath]
                }
                if case let .done(url) = phase {
                    continuation.resume(returning: url)
                    return
                }
                let destination = self.destinationDirectory
                    .appendingPathComponent(artifact.destinationFileName)
                if FileManager.default.fileExists(atPath: destination.path), self.isAdoptable(artifact, at: destination) {
                    // Prepared by an earlier launch: adopt it, don't re-decompress.
                    self.setPhase(artifact, to: .done(destination))
                    self.afterPrepare(artifact, promoted: destination)
                    continuation.resume(returning: destination)
                    return
                }
                do {
                    let url = try self.prepareArtifact(artifact, destination: destination)
                    self.afterPrepare(artifact, promoted: url)
                    self.setPhase(artifact, to: .done(url))
                    continuation.resume(returning: url)
                } catch {
                    // Retryable: a later prepare (or next launch) starts over.
                    self.setPhase(artifact, to: .idle)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Serial-queue runs only (the queue is the coalescing point — see
    /// `Phase`); the mutex keeps `phases` compiler-checked Sendable.
    private func setPhase(_ artifact: Artifact, to phase: Phase) {
        phases.withLock { current in
            current[keyPath: artifact.phaseKeyPath] = phase
        }
    }

    /// Whether a file already at the destination can be adopted as-is.
    ///
    /// **The single authority on this.** Nothing upstream may decide it from a
    /// file's existence: `resolveJMDict()` answers "where is the artifact", not
    /// "is the artifact usable", and a caller that gates on it would adopt an
    /// index-less database forever. `run` is reached unconditionally, and this
    /// is what it asks.
    ///
    /// Existence is the whole staleness key for the tokenizer dictionary. It is
    /// not enough for JMDict: a database promoted before the gloss index existed
    /// is complete and current, yet answers every Latin query with zero rows and
    /// no error — the stage's `LIKE` scan is gone and there is nothing to fall
    /// back to. Adoption therefore requires the gloss index at the current
    /// `JMDictFTSIndex.schemaVersion` **and** the case-headword index by
    /// presence alone (its DDL cannot drift — see `JMDictCaseIndex`), so a
    /// database promoted before either existed re-stages once and comes back
    /// carrying both.
    ///
    /// This is load-bearing rather than an optimization, and it is why the
    /// *filename* deliberately does not encode the index: bumping
    /// `JMDictPin.buildRevision` for it would force a full ingestion rebuild
    /// and rename the shipped artifact for every user, which is a far larger
    /// change than the situation warrants. Existing installs instead re-stage
    /// themselves once — one decompress plus ~2 s — and are then adopted
    /// normally. The cost when the database *is* current is one `fileExists`
    /// plus a couple of `sqlite_master` probes on a lazily-opened handle.
    ///
    /// A platform with no FTS5 is the one case where a missing gloss index is
    /// correct: the gloss build is fail-soft there by design, so requiring it
    /// unconditionally would re-decompress and rebuild on every launch forever.
    /// The case index needs no such escape — a plain `CREATE INDEX` works on
    /// any SQLite, which is why its build runs before the gloss build — so the
    /// escape hatch still yields a database whose case load is served from the
    /// index.
    private func isAdoptable(_ artifact: Artifact, at url: URL) -> Bool {
        switch artifact {
        case .tokenizer: true
        case .jmDict:
            (JMDictFTSIndex.isPresent(at: url) && JMDictCaseIndex.isPresent(at: url))
                || !JMDictFTSIndex.isAvailable
        }
    }

    /// Post-promote hook: the JMDict artifact's versioned filename is its
    /// staleness key, so stale artifacts from earlier pins are swept after
    /// each successful promote or adoption. The tokenizer artifact has no
    /// version to sweep.
    private func afterPrepare(_ artifact: Artifact, promoted url: URL) {
        guard artifact == .jmDict else { return }
        removeLegacyJMDictArtifacts(keeping: url)
    }

    /// Runs on the serial queue. Stages a private copy of the artifact's zst
    /// and decompresses it into a private temp directory, smoke-checks the
    /// result, and only then promotes it into place — a failure at any stage
    /// leaves no partial file at the destination.
    private func prepareArtifact(_ artifact: Artifact, destination: URL) throws -> URL {
        guard let source = self[keyPath: artifact.sourceKeyPath] else {
            throw artifact.missingSourceError
        }
        guard let ffi else {
            throw DictionaryStoreError.libraryUnavailable
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("mimidasu-dictionary-prepare-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // The FFI reads the zst from disk; stage a private copy so the
        // decompress neither touches the bundle nor aliases the caller's file.
        let stagedZst = staging.appendingPathComponent("artifact.zst")
        try fm.copyItem(at: source, to: stagedZst)
        let stagedArtifact = staging.appendingPathComponent(artifact.destinationFileName)

        let returnCode = ffi.prepare(stagedZst.path, stagedArtifact.path)
        guard returnCode == 0 else {
            throw DictionaryStoreError.prepareFailed(returnCode: returnCode)
        }
        // The gloss index is derived here, on the staged copy, before the smoke
        // check — so the smoke check exercises the path the app will actually
        // run and a silently-empty index fails the promote instead of shipping.
        let indexed = try indexJMDict(stagedArtifact)
        try smoke(artifact, stagedArtifact, indexed: indexed, ffi: ffi)

        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: stagedArtifact, to: destination)
        return destination
    }

    /// The artifact-specific smoke check. The tokenizer opens the staged
    /// dictionary through the FFI; the JMDict database goes through the
    /// lookup engine (`学生` must hit ≥1 entry in both).
    private func smoke(
        _ artifact: Artifact, _ stagedArtifact: URL,
        indexed: Bool, ffi: DictionaryFFI
    ) throws {
        switch artifact {
        case .tokenizer: try smokeQuery(stagedArtifact, ffi: ffi)
        case .jmDict: try smokeQueryJMDict(stagedArtifact, indexed: indexed)
        }
    }

    /// Builds the gloss index over a staged JMDict database, and reports
    /// whether it is there afterwards.
    ///
    /// Two failure classes, deliberately not treated alike.
    ///
    /// A platform whose SQLite cannot create an FTS5 table is an
    /// environmental degradation: the dictionary is perfectly usable and the
    /// only casualty is Latin gloss search, so it is logged and reported as "no
    /// index" rather than costing the user their dictionary. That is also why
    /// `smokeQueryJMDict` only asserts an index when one was built.
    ///
    /// A corpus that does not fit the `rowid` pack is not a degradation, it is
    /// a schema violation: promoting it would alias rowids and hand the stage
    /// another entry's gloss, silently and on every query. That fails the
    /// prepare, discards the staging directory, and retries next launch — the
    /// correct outcome, because there is no degraded-but-useful version of it.
    ///
    /// The case-headword index built beside it is independent of the gloss
    /// build — it runs first, and a plain `CREATE INDEX` needs no FTS5 — but
    /// it is treated the same soft way, because its absence costs latency
    /// once, never answers.
    private func indexJMDict(_ stagedArtifact: URL) throws -> Bool {
        buildCaseIndex(stagedArtifact)
        do {
            try JMDictFTSIndex.build(at: stagedArtifact)
        } catch let error as JMDictFTSIndex.IndexError {
            throw error
        } catch {
            print("[dictionary-store] gloss index unavailable: \(error)")
            return false
        }
        return JMDictFTSIndex.isPresent(at: stagedArtifact)
    }

    /// Builds the case-headword index over the same staged copy, before the
    /// gloss build so a no-FTS5 platform still gets it — the statement is a
    /// plain `CREATE INDEX` and needs no FTS5, and `isAdoptable` expects the
    /// promoted database to carry it.
    ///
    /// Fail-soft, though no longer consequence-free: adoption requires the
    /// index, so a staged database whose case build failed here is promoted
    /// and then re-staged on every later launch. That loop is bounded by
    /// reality — `CREATE INDEX` over a freshly staged writable copy fails only
    /// where the rest of the prepare fails too (a full disk fails the
    /// promote's move, corruption fails the smoke check) — and nothing reads
    /// the index: the engine loads the same 2,357 spellings either way,
    /// walking the `headwords` B-tree once per launch (~100 ms) instead of
    /// scanning a 57 KB covering index (0.8 ms). A failure is logged and the
    /// dictionary is promoted.
    private func buildCaseIndex(_ stagedArtifact: URL) {
        do {
            try JMDictCaseIndex.build(at: stagedArtifact)
        } catch {
            print("[dictionary-store] case-headword index unavailable: \(error)")
        }
    }

    /// Proves the freshly decompressed dictionary is openable and actually
    /// answers queries: the smoke word must tokenize with a non-null reading
    /// (an open-but-corrupt dictionary would not be caught by open alone).
    private func smokeQuery(_ dicURL: URL, ffi: DictionaryFFI) throws {
        guard let handle = ffi.open(dicURL.path) else {
            throw DictionaryStoreError.smokeTestFailed(reason: "open returned null")
        }
        defer { ffi.free(handle) }
        guard let tokens = ffi.tokenize(handle, Self.smokeWord) else {
            throw DictionaryStoreError.smokeTestFailed(reason: "tokenize returned null")
        }
        guard tokens.contains(where: { token in token.reading != nil }) else {
            throw DictionaryStoreError.smokeTestFailed(
                reason: "no reading for \(Self.smokeWord)"
            )
        }
    }

    /// JMDict smoke check, delegated to the JMDict lookup engine: the smoke
    /// word must hit at least one entry in the staged database. A corrupt or
    /// truncated database surfaces here as the lookup's SQLite error, not as
    /// a silent pass (an open alone would succeed — SQLite opens lazily).
    ///
    /// When an index was built it must also *answer* — a present-but-empty
    /// `gloss_fts` passes every schema probe and then returns nothing for every
    /// query, which is indistinguishable from a word that has no gloss.
    /// `indexed` is false only where this platform has no FTS5, which
    /// `indexJMDict` has already logged.
    private func smokeQueryJMDict(_ databaseURL: URL, indexed: Bool) throws {
        let lookup = JMDictLookup(resolveDatabase: { databaseURL })
        do {
            guard try lookup.lookup(LookupCandidate(text: Self.smokeWord)) != nil else {
                throw DictionaryStoreError.smokeTestFailed(
                    reason: "no entry for \(Self.smokeWord)"
                )
            }
        } catch let error as JMDictLookupError {
            throw DictionaryStoreError.smokeTestFailed(reason: error.localizedDescription)
        }
        guard indexed else { return }
        guard JMDictFTSIndex.answers(at: databaseURL) else {
            throw DictionaryStoreError.smokeTestFailed(reason: "gloss index answers nothing")
        }
    }

    /// The versioned filename is the staleness key: after a successful
    /// promote (or adoption), any other prepared `jmdict-*.sqlite` in the
    /// destination directory is a stale artifact from an earlier pin and is
    /// removed — best-effort, a failed cleanup must never fail the prepare.
    private func removeLegacyJMDictArtifacts(keeping current: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: destinationDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents
            where url.lastPathComponent.hasPrefix(JMDictPin.artifactPrefix)
            && url.lastPathComponent.hasSuffix("." + JMDictPin.artifactExtension)
            && url.standardizedFileURL != current.standardizedFileURL
        {
            try? fm.removeItem(at: url)
        }
    }
}
