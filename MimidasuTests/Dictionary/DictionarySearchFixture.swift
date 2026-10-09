import Foundation
@testable import Mimidasu
import Testing

/// A throwaway fixture database plus a search engine over it, with the
/// teardown Swift Testing has no hook for: the suite's own lifetime ends the
/// database, and the SQLite handle is closed before the file goes. A class
/// because only a reference type can clean up after itself on `deinit`.
final class DictionarySearchFixture {
    let engine: DictionarySearchEngine
    /// The fixture file, for tests that open their own handle to read the rows
    /// the engine's SQL shapes produce.
    let url: URL
    private let built: JMDictFixtureDatabase.Built

    init(
        tokenize: @escaping @Sendable (String) -> [DictionaryToken]? = { _ in nil },
        extraWords: [JMDictFixtureDatabase.FixtureWord] = []
    ) throws {
        built = try JMDictFixtureDatabase.build(extraWords: extraWords)
        let url = built.url
        self.url = url
        engine = DictionarySearchEngine(resolveDatabase: { url }, tokenize: tokenize)
    }

    func outcome(
        _ query: String,
        scope: DictionarySearchFilters.Scope = .all,
        commonOnly: Bool = false,
        limit: Int = DictionarySearchEngine.pageSize
    ) throws -> DictionarySearchOutcome {
        try engine.search(
            query, filters: DictionarySearchFilters(scope: scope, commonOnly: commonOnly),
            limit: limit
        )
    }

    deinit {
        // Close before unlinking — SQLite complains loudly about a vnode
        // removed underneath an open handle.
        engine.close()
        built.remove()
    }
}
