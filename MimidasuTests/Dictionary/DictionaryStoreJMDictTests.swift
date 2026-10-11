import Foundation
@testable import Mimidasu
import Testing

// MARK: - DictionaryStore: second artifact (JMDict)

//
// JMDict-side tests for `DictionaryStore`: versioned resolve/staging, the
// lookup-engine smoke query, and stale-artifact cleanup. Declared as an
// extension of `DictionaryStoreTests` so both artifact halves run inside the
// same serialized suite — the fake FFI state they share is file-scope mutable
// (see DictionaryStoreTests.swift).

extension DictionaryStoreTests {

    // MARK: errorDescription

    @Test("names the missing bundled JMDict artifact")
    func bundledJMDictMissingMessage() {
        let error = DictionaryStore.DictionaryStoreError.bundledJMDictMissing

        #expect(
            error.errorDescription
                == "Bundled \(JMDictPin.bundledFileName) not found in the app bundle."
        )
    }

    @Test("names a failed index build apart from a failed smoke query")
    func indexBuildFailedMessage() {
        let index = DictionaryStore.DictionaryStoreError.indexBuildFailed(
            reason: "SQLite error 8: attempt to write a readonly database"
        )

        // Distinct copy: the two failures surface the same way to the user (a
        // prepare that failed and retries), and the status bar must not claim
        // a smoke query failed when the index build is what stopped it.
        #expect(
            index.errorDescription
                == "Dictionary index could not be built: SQLite error 8: "
                + "attempt to write a readonly database."
        )
    }

    // MARK: resolveJMDict

    #if DEBUG
        @Test("resolves the MIMIDASU_JMDICT override set on the process")
        func jmDictProcessEnvOverride() throws {
            let overrideURL = tempRoot.appendingPathComponent("override-jmdict.sqlite")
            try Data("sqlite".utf8).write(to: overrideURL)
            dictionaryEnvLock.lock()
            defer { dictionaryEnvLock.unlock() }
            setenv("MIMIDASU_JMDICT", overrideURL.path, 1)
            defer { unsetenv("MIMIDASU_JMDICT") }

            let resolved = DictionaryStore.resolveJMDict()

            #expect(resolved?.path == overrideURL.path)
        }
    #endif

    @Test("returns the default versioned location when it exists")
    func resolvesJMDictDefaultLocation() {
        let defaultExists: (URL) -> Bool = { url in url.pathComponents.contains("dictionaries") }

        let url = DictionaryStore.resolveJMDict(environment: [:], fileExists: defaultExists)

        #expect(url == DictionaryStore.defaultJMDictURL)
    }

    @Test("prefers an existing MIMIDASU_JMDICT override")
    func jmDictEnvOverrideWins() {
        let overridePath = "/custom/jmdict.sqlite"
        let overrideExists: (URL) -> Bool = { url in url.path == overridePath }

        let url = DictionaryStore.resolveJMDict(
            environment: ["MIMIDASU_JMDICT": overridePath], fileExists: overrideExists
        )

        #expect(url?.path == overridePath)
    }

    @Test("falls through to the default location when the MIMIDASU_JMDICT override is missing")
    func jmDictMissingEnvOverrideFallsThrough() {
        let missingOverride = "/missing/jmdict.sqlite"
        let defaultExists: (URL) -> Bool = { url in url.pathComponents.contains("dictionaries") }

        let url = DictionaryStore.resolveJMDict(
            environment: ["MIMIDASU_JMDICT": missingOverride], fileExists: defaultExists
        )

        #expect(url == DictionaryStore.defaultJMDictURL)
    }

    @Test("returns nil when no JMDict candidate exists")
    func jmDictNothingResolves() {
        let nothingExists: (URL) -> Bool = { _ in false }

        let url = DictionaryStore.resolveJMDict(environment: [:], fileExists: nothingExists)

        #expect(url == nil)
    }

    // MARK: default locations

    @Test("composes the versioned JMDict destination path from the pin")
    func defaultJMDictPath() {
        let path = DictionaryStore.defaultJMDictURL.path

        #if DEBUG
            // Debug checkouts prepare inside the repo; the user's home
            // directory stays untouched.
            #expect(path.hasSuffix("build/prepared/dictionaries/\(JMDictPin.preparedFileName)"))
        #else
            #expect(path.hasSuffix("Mimidasu/dictionaries/\(JMDictPin.preparedFileName)"))
        #endif
    }

    // MARK: prepareJMDict (fake runtime)

    @Test("decompresses the JMDict artifact into the versioned destination on first launch")
    func jmDictFirstPrepareMovesIntoPlace() async throws {
        fakePrepareCopySource = smokeDatabase
        let store = makeStore()

        let url = try await store.prepareJMDict()

        #expect(url == destination.appendingPathComponent(JMDictPin.preparedFileName))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("adopts a JMDict database prepared by an earlier launch without decompressing")
    func jmDictAdoptsExistingDestination() async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent(JMDictPin.preparedFileName)
        // Adoption is index-aware, so the file left by the "earlier launch"
        // has to carry the gloss index at its current stamp — otherwise the
        // store is right to re-stage it.
        let adopted = copyOf(smokeDatabase, to: existing)
        try JMDictFTSIndex.build(at: adopted)
        let store = makeStore()

        let url = try await store.prepareJMDict()

        #expect(url == existing)
        #expect(fakePrepareCalls == 0, "an existing database must short-circuit the decompress")
    }

    @Test("re-stages a JMDict database prepared before the gloss index existed")
    func jmDictReStagesIndexLessDatabase() async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent(JMDictPin.preparedFileName)
        try FileManager.default.copyItem(at: smokeDatabase, to: existing)
        #expect(!JMDictFTSIndex.isPresent(at: existing))
        fakePrepareCopySource = smokeDatabase
        let store = makeStore()

        let url = try await store.prepareJMDict()

        // With the `LIKE` scan deleted, an index-less database answers every
        // Latin query with zero rows and no error — so it must not be adopted.
        // This is the self-heal for every install that promoted before the
        // index existed.
        #expect(fakePrepareCalls == 1)
        #expect(JMDictFTSIndex.isPresent(at: url))
        #expect(JMDictFTSIndex.answers(at: url))
    }

    @Test("adopts a JMDict database whose case-headword index is missing")
    func jmDictAdoptsCaseIndexLessDatabase() async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent(JMDictPin.preparedFileName)
        // A database whose gloss index is current — stamped, answering — but
        // which carries no case-headword index. That shape cannot reach the
        // destination through the rev-7 artifact, so it means a regressed or
        // hand-placed database; the store adopts it anyway. The index's
        // absence never changes an answer, only the cost of the case-spelling
        // load, and with no runtime builder left, gating here would turn that
        // latency into a re-decompress on every launch.
        let earlier = copyOf(smokeDatabase, to: existing)
        try JMDictFTSIndex.build(at: earlier)
        #expect(JMDictFTSIndex.isPresent(at: existing))
        let database = try SQLiteDatabase(path: existing.path)
        let presence = try database.statement(
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'headwords_case'"
        )
        #expect(try presence.step() == false)
        database.close()
        let store = makeStore()

        let url = try await store.prepareJMDict()

        #expect(fakePrepareCalls == 0, "a latency-only degradation must not force a re-stage")
        #expect(url == existing)
    }

    @Test("stamps the index so a DDL change can outrun the filename")
    func jmDictBuildStampsTheIndex() async throws {
        fakePrepareCopySource = smokeDatabase
        let store = makeStore()

        let url = try await store.prepareJMDict()

        let database = try SQLiteDatabase(path: url.path)
        defer { database.close() }
        let stamp = try database.statement(JMDictFTSIndex.schemaVersionSQL)
        #expect(try stamp.step())
        #expect(stamp.requiredInt(0) == JMDictFTSIndex.schemaVersion)
    }

    @Test("re-stages an index built against an older schema version")
    func jmDictReStagesStaleIndex() async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent(JMDictPin.preparedFileName)
        _ = copyOf(smokeDatabase, to: existing)
        // A database whose `gloss_fts` exists under the current name but was
        // built from different constants is the dangerous case: the search
        // stage's `rowid >> 7` / `rowid & 127` decode would read the wrong
        // `ord` off every row and hand back another entry's gloss, with no
        // error anywhere in the stack. Name presence cannot catch that; the
        // stamp can.
        try JMDictFTSIndex.build(at: existing)
        let stale = try SQLiteDatabase.writable(path: existing.path)
        try stale.execute("PRAGMA user_version = 0")
        stale.close()
        #expect(!JMDictFTSIndex.isPresent(at: existing))
        fakePrepareCopySource = smokeDatabase
        let store = makeStore()

        let url = try await store.prepareJMDict()

        #expect(fakePrepareCalls == 1)
        #expect(JMDictFTSIndex.isPresent(at: url))
    }

    @Test("this platform can build an FTS5 index, so a missing one means re-stage")
    func platformHasFTS5() {
        // Pins the assumption the adoption guard is built on. `isAdoptable`
        // re-stages a database with no index *because* this is true — without
        // it, a platform where the build is legitimately fail-soft would
        // re-decompress on every launch forever. On a host without FTS5 this
        // expectation is the thing that has to change.
        #expect(SQLiteDatabase.supportsFTS5)
        #expect(JMDictFTSIndex.isAvailable)
    }

    /// `content` copied to `url`, which the caller then treats as the artifact.
    private func copyOf(_ content: URL, to url: URL) -> URL {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: content, to: url)
        return url
    }

    @Test("is a no-op once the JMDict database is prepared")
    func jmDictSecondPrepareIsNoOp() async throws {
        fakePrepareCopySource = smokeDatabase
        let store = makeStore()
        let prepared = try await store.prepareJMDict()

        let second = try await store.prepareJMDict()

        #expect(second == prepared, "a successful prepare must never re-decompress")
        #expect(fakePrepareCalls == 1)
    }

    @Test("coalesces concurrent JMDict callers into one decompression")
    func jmDictConcurrentCallersCoalesce() async throws {
        fakePrepareCopySource = smokeDatabase
        // Short but guaranteed to overlap: late callers line up behind the
        // in-flight decompression and observe the done phase.
        fakePrepareDelayMs = 50
        let store = makeStore()

        async let first = store.prepareJMDict()
        async let second = store.prepareJMDict()
        async let third = store.prepareJMDict()
        let results = try await (first, second, third)

        #expect(results.0 == results.1 && results.1 == results.2)
        #expect(fakePrepareCalls == 1, "all callers must share the single decompression")
    }

    @Test("removes stale versioned JMDict artifacts after a successful promote")
    func jmDictPromoteRemovesLegacyArtifacts() async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stale = destination.appendingPathComponent("jmdict-0.9.9-auto-release-old.sqlite")
        try Data("stale pin".utf8).write(to: stale)
        fakePrepareCopySource = smokeDatabase
        let store = makeStore()

        let url = try await store.prepareJMDict()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("reports a JMDict decompression failure and leaves no partial database")
    func jmDictPrepareFailureLeavesNoPartialFile() async throws {
        let store = makeStore(ffi: makeFakeFFI(prepare: fakePrepareFail))

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        #expect(error == .prepareFailed(returnCode: 1))
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(JMDictPin.preparedFileName).path
            ),
            "a failed prepare must not leave a partial database"
        )
    }

    @Test("re-attempts the JMDict decompression on the next call after a failure")
    func jmDictFailedPrepareRetries() async throws {
        let store = makeStore(ffi: makeFakeFFI(prepare: fakePrepareFail))
        _ = try? await store.prepareJMDict()

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        #expect(error == .prepareFailed(returnCode: 1))
        #expect(fakePrepareCalls == 2, "the retry must re-attempt the decompression")
    }

    @Test("fails the JMDict prepare when the artifact is not a database")
    func jmDictSmokeRejectsNonDatabase() async throws {
        // The default fake prepare writes the plain placeholder payload —
        // not SQLite — so the derived index cannot be built on it, and the
        // prepare must fail rather than promote a file no engine can read.
        let store = makeStore()

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        guard case let .indexBuildFailed(reason) = error else {
            Issue.record("expected .indexBuildFailed, got \(error)")
            return
        }
        #expect(reason.contains("file is not a database"))
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(JMDictPin.preparedFileName).path
            )
        )
    }

    @Test("fails the JMDict smoke query when the smoke word has no entry")
    func jmDictSmokeRejectsEntryLessDatabase() async throws {
        let entryLess = try makeJMDictSmokeDatabase(includeSmokeWord: false)
        defer { try? FileManager.default.removeItem(at: entryLess.deletingLastPathComponent()) }
        fakePrepareCopySource = entryLess
        let store = makeStore()

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        #expect(error == .smokeTestFailed(reason: "no entry for 学生"))
    }

    @Test("refuses to promote a database whose gloss index cannot answer")
    func jmDictSmokeRejectsSilentEmptyIndex() async throws {
        // The lookup passes — 学生 exists — but every sense carries no gloss, so
        // the index builds and answers nothing. Promoting this would ship a
        // dictionary whose Latin search silently returns zero rows for every
        // query, which is exactly how a broken index presents.
        let glossless = try makeJMDictSmokeDatabase(emptyGloss: true)
        defer { try? FileManager.default.removeItem(at: glossless.deletingLastPathComponent()) }
        fakePrepareCopySource = glossless
        let store = makeStore()

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        #expect(error == .smokeTestFailed(reason: "gloss index answers nothing"))
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(JMDictPin.preparedFileName).path
            ),
            "a database with a silent-empty index must not be promoted"
        )
    }

    @Test("refuses to build an index whose rowid encoding would alias")
    func jmDictRefusesOverflowingEntry() async throws {
        // Seven bits address `ord`, and the pack is `entry_id * 128 + ord`.
        // Senses are numbered from zero, so 128 of them fit exactly; the 129th
        // has `ord = 128` and would collide onto the next entry's first rowid,
        // making the stage read back a different entry's gloss with no error
        // anywhere. The build fails instead — and unlike a missing FTS5 module,
        // this is *not* fail-soft: there is no degraded-but-usable version of
        // an index that returns the wrong rows.
        let overflowing = try makeJMDictSmokeDatabase(sensesPerEntry: 129)
        defer {
            try? FileManager.default.removeItem(at: overflowing.deletingLastPathComponent())
        }
        fakePrepareCopySource = overflowing
        let store = makeStore()

        let error = await #expect(throws: JMDictFTSIndex.IndexError.self) {
            try await store.prepareJMDict()
        }

        #expect(error == .senseCountOverflow(maxOrd: 128))
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(JMDictPin.preparedFileName).path
            ),
            "a database that cannot be indexed safely must not be promoted"
        )
    }

    /// Fail-soft is for exactly one failure: a platform whose SQLite cannot
    /// create an FTS5 table at all. A read-only staged artifact stands in for
    /// every *transient* one — a full disk mid-insert of the ~140 MB index, an
    /// I/O error — none of which are degradation. Swallowing them promoted an
    /// index-less database that `isAdoptable` then rejected on every later
    /// launch (FTS5 being available here, the index is not optional), so the
    /// store decompressed, failed, and promoted again forever, silently. The
    /// prepare must fail loudly instead, leaving nothing behind.
    @Test("refuses to degrade a transient index-build failure into a silent promote")
    func jmDictTransientIndexFailureIsNotFailSoft() async throws {
        // A read-only staged copy: `senses` reads fine, so the lookup smoke
        // passes and the index build is the only thing that fails — the shape of
        // a mid-insert disk-full, where the database itself is still valid.
        // This leans on FileManager.copyItem preserving the 0444 mode through
        // both copies it feeds (production staging, then the fake prepare);
        // were that ever to change, the index would build and this test would
        // fail loudly below — never silently pass.
        let staged = tempRoot.appendingPathComponent("read-only-source.sqlite")
        try FileManager.default.copyItem(at: smokeDatabase, to: staged)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: staged.path
        )
        defer { try? FileManager.default.removeItem(at: staged) }
        fakePrepareCopySource = staged
        let store = makeStore()

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        // Exact equality pins the whole `describe` format, code included.
        #expect(
            error == .indexBuildFailed(
                reason: "SQLite error 8: attempt to write a readonly database"
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(JMDictPin.preparedFileName).path
            ),
            "an index-less database must never be promoted on a platform that can build one"
        )
    }

    @Test("accepts an entry carrying the most senses the rowid pack can address")
    func jmDictAcceptsTheSenseCountLimit() async throws {
        // One below the refusal: the boundary is inclusive, so 127 senses still
        // encodes and the prepare completes normally. Without this, "the
        // builder refuses" would be satisfied by a threshold that is simply
        // too low.
        let atLimit = try makeJMDictSmokeDatabase(sensesPerEntry: 127)
        defer { try? FileManager.default.removeItem(at: atLimit.deletingLastPathComponent()) }
        fakePrepareCopySource = atLimit
        let store = makeStore()

        let url = try await store.prepareJMDict()

        #expect(JMDictFTSIndex.isPresent(at: url))
    }

    @Test("fails when the bundled JMDict artifact is missing")
    func jmDictBundledSourceMissing() async throws {
        let store = DictionaryStore(
            bundledSource: fixtureZst, bundledJMDictSource: nil,
            destinationDirectory: destination, ffi: makeFakeFFI()
        )

        let error = await #expect(throws: DictionaryStore.DictionaryStoreError.self) {
            try await store.prepareJMDict()
        }

        #expect(error == .bundledJMDictMissing)
        #expect(fakePrepareCalls == 0)
    }

    // MARK: prepareJMDict (live runtime)

    @Test("decompresses the real built JMDict artifact on first launch")
    func jmDictLiveFirstLaunchDecompresses() async throws {
        guard let ffi = DictionaryFFI.load() else {
            try Test.cancel("libdictionary.dylib is not available")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let artifact = root.appendingPathComponent("local/dictionaries/\(JMDictPin.bundledFileName)")
        guard FileManager.default.fileExists(atPath: artifact.path) else {
            try Test.cancel("the built JMDict artifact is not available")
        }
        let store = DictionaryStore(
            bundledSource: nil, bundledJMDictSource: artifact,
            destinationDirectory: destination, ffi: ffi
        )

        let url = try await store.prepareJMDict()

        #expect(FileManager.default.fileExists(atPath: url.path))
        // The artifact is the only source of the case-headword index now, so
        // the promoted database must carry it straight from the decompress.
        let database = try SQLiteDatabase(path: url.path)
        defer { database.close() }
        let presence = try database.statement(
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'headwords_case'"
        )
        #expect(try presence.step())
    }
}
