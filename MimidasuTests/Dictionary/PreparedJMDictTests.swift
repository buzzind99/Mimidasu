import Foundation
@testable import Mimidasu
import Testing

/// `PreparedJMDict`'s contract: which artifact resolution picks, which files
/// adoption accepts, and how each open failure surfaces. The engine agreement
/// cases pin that lookup and search report the same infrastructure failure for
/// the same path.
@Suite("PreparedJMDict")
struct PreparedJMDictTests {
    private let destination = URL(fileURLWithPath: "/tmp/prepared-jmdict-tests", isDirectory: true)

    // MARK: - Resolution

    #if DEBUG
        @Test("prefers the MIMIDASU_JMDICT override over every prepared location")
        func environmentOverrideWins() {
            let overrideURL = URL(fileURLWithPath: "/custom/jmdict.sqlite")
            let prepared = destination.appendingPathComponent(JMDictPin.preparedFileName)
            let checkout = DictionaryStore.debugRepoURL(JMDictPin.debugCheckoutPath)
            let existing: (URL) -> Bool = { url in
                url == overrideURL || url == prepared || url == checkout
            }

            let resolved = PreparedJMDict.resolve(
                environment: ["MIMIDASU_JMDICT": overrideURL.path],
                destination: destination,
                fileExists: existing
            )

            #expect(resolved?.url == overrideURL)
        }
    #endif

    #if DEBUG
        @Test("prefers the prepared destination over the debug checkout")
        func preparedDestinationWins() {
            let prepared = destination.appendingPathComponent(JMDictPin.preparedFileName)
            let checkout = DictionaryStore.debugRepoURL(JMDictPin.debugCheckoutPath)
            let existing: (URL) -> Bool = { url in url == prepared || url == checkout }

            let resolved = PreparedJMDict.resolve(
                environment: [:], destination: destination, fileExists: existing
            )

            #expect(resolved?.url == prepared)
        }
    #endif

    @Test("returns nil when no candidate exists")
    func nothingResolves() {
        let nothingExists: (URL) -> Bool = { _ in false }

        let resolved = PreparedJMDict.resolve(
            environment: [:], destination: destination, fileExists: nothingExists
        )

        #expect(resolved == nil)
    }

    @Test("the store facade returns the URL the resolver picks")
    func facadeMatchesResolution() {
        let overrideURL = URL(fileURLWithPath: "/custom/jmdict.sqlite")
        let defaultURL = DictionaryStore.defaultJMDictURL
        let existing: (URL) -> Bool = { url in url == overrideURL || url == defaultURL }

        let resolved = PreparedJMDict.resolve(
            environment: ["MIMIDASU_JMDICT": overrideURL.path], fileExists: existing
        )?.url
        let facade = DictionaryStore.resolveJMDict(
            environment: ["MIMIDASU_JMDICT": overrideURL.path], fileExists: existing
        )

        #expect(facade != nil)
        #expect(facade == resolved)
    }

    #if DEBUG
        @Test("resolves the MIMIDASU_JMDICT override from the process environment")
        func processEnvironmentOverride() throws {
            let overrideURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("mimidasu-prepared-override-\(UUID().uuidString).sqlite")
            try Data("sqlite".utf8).write(to: overrideURL)
            defer { try? FileManager.default.removeItem(at: overrideURL) }
            dictionaryEnvLock.lock()
            defer { dictionaryEnvLock.unlock() }
            setenv("MIMIDASU_JMDICT", overrideURL.path, 1)
            defer { unsetenv("MIMIDASU_JMDICT") }

            let resolved = PreparedJMDict.resolve()

            #expect(resolved?.url.path == overrideURL.path)
        }
    #endif

    // MARK: - Adoption

    @Test("adopts a stamped fixture carrying the gloss index")
    func adoptsIndexedFixture() throws {
        let built = try JMDictFixtureDatabase.build()
        defer { built.remove() }

        #expect(PreparedJMDict.isAdoptable(at: built.url))
    }

    @Test("rejects a database whose gloss index was dropped")
    func rejectsIndexlessDatabase() throws {
        guard JMDictFTSIndex.isAvailable else {
            try Test.cancel("FTS5 is unavailable on this host")
        }
        let built = try JMDictFixtureDatabase.build()
        defer { built.remove() }
        let indexless = try makeIndexlessCopy(of: built)

        #expect(PreparedJMDict.isAdoptable(at: indexless) == false)
    }

    @Test("rejects a missing file")
    func rejectsMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-prepared-missing-\(UUID().uuidString).sqlite")

        #expect(PreparedJMDict.isAdoptable(at: missing) == false)
    }

    // MARK: - Open

    @Test("opens an indexed fixture and reports the gloss index")
    func opensIndexedFixture() throws {
        let built = try JMDictFixtureDatabase.build()
        defer { built.remove() }
        let opened = try PreparedJMDict(url: built.url).open()
        defer { opened.database.close() }

        #expect(opened.hasGlossIndex)
    }

    @Test("opens an index-less database and reports no gloss index")
    func opensIndexlessDatabase() throws {
        guard JMDictFTSIndex.isAvailable else {
            try Test.cancel("FTS5 is unavailable on this host")
        }
        let built = try JMDictFixtureDatabase.build()
        defer { built.remove() }
        let indexless = try makeIndexlessCopy(of: built)
        let opened = try PreparedJMDict(url: indexless).open()
        defer { opened.database.close() }

        #expect(opened.hasGlossIndex == false)
    }

    @Test("throws databaseMissing for a missing file")
    func missingFileThrowsDatabaseMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-prepared-missing-\(UUID().uuidString).sqlite")

        let thrown = #expect(throws: DictionaryError.self) {
            _ = try PreparedJMDict(url: missing).open()
        }

        #expect(thrown == .databaseMissing)
    }

    @Test("throws a sqlite error for a file that is not SQLite")
    func nonSQLiteFileThrowsSQLiteError() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-prepared-garbage-\(UUID().uuidString).sqlite")
        try Data("definitely not a sqlite database".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let thrown = #expect(throws: DictionaryError.self) {
            _ = try PreparedJMDict(url: url).open()
        }

        #expect(isSQLiteError(thrown))
    }

    @Test("throws a sqlite error for an unopenable directory path")
    func directoryPathThrowsSQLiteError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mimidasu-prepared-directory-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let thrown = #expect(throws: DictionaryError.self) {
            _ = try PreparedJMDict(url: directory).open()
        }

        #expect(isSQLiteError(thrown))
    }

    // MARK: - Engine agreement

    @Test("both engines report a non-SQLite file as a sqlite error")
    func enginesAgreeOnNonSQLiteFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-prepared-garbage-\(UUID().uuidString).sqlite")
        try Data("definitely not a sqlite database".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let lookup = JMDictLookup(resolveDatabase: { [url] in url })
        let search = DictionarySearchEngine(
            resolveDatabase: { [url] in url },
            tokenize: { _ in nil }
        )
        defer {
            lookup.close()
            search.close()
        }

        let lookupError = try #require(
            #expect(throws: DictionaryError.self) {
                try lookup.lookup(LookupCandidate(text: "食べる"))
            }
        )
        let searchError = try #require(
            #expect(throws: DictionaryError.self) {
                try search.search("食べる", filters: DictionarySearchFilters())
            }
        )

        #expect(lookupError == searchError)
        #expect(isSQLiteError(lookupError))
    }

    @Test("both engines report a missing path as databaseMissing")
    func enginesAgreeOnMissingPath() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-prepared-missing-\(UUID().uuidString).sqlite")
        let lookup = JMDictLookup(resolveDatabase: { missing })
        let search = DictionarySearchEngine(
            resolveDatabase: { missing },
            tokenize: { _ in nil }
        )
        defer {
            lookup.close()
            search.close()
        }

        let lookupError = #expect(throws: DictionaryError.self) {
            try lookup.lookup(LookupCandidate(text: "食べる"))
        }
        let searchError = #expect(throws: DictionaryError.self) {
            try search.search("食べる", filters: DictionarySearchFilters())
        }

        #expect(lookupError == .databaseMissing)
        #expect(searchError == .databaseMissing)
    }

    // MARK: - Helpers

    private func makeIndexlessCopy(of built: JMDictFixtureDatabase.Built) throws -> URL {
        let indexless = built.url.deletingLastPathComponent()
            .appendingPathComponent("indexless-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: built.url, to: indexless)
        let database = try SQLiteDatabase.writable(path: indexless.path)
        defer { database.close() }
        try database.execute(JMDictFTSIndex.dropSQL)
        return indexless
    }

    private func isSQLiteError(_ error: DictionaryError?) -> Bool {
        guard let error else { return false }
        if case .sqliteError = error {
            return true
        }
        return false
    }
}
