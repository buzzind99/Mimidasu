import Foundation
@testable import Mimidasu
import Testing

/// Tests `ModelRemoval` against a scratch directory: the unlink and the
/// verdict-cache eviction happen together, and a failed unlink leaves the
/// verdict alone so the cache never claims a file that is still there.
@Suite("Model removal")
struct ModelRemovalTests {

    private let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory(prefix: "mimidasu-removal")
    }

    private func makeStore() -> ModelVerifier.VerdictStore {
        ModelVerifier.VerdictStore(url: temporary.fileURL("verdicts.json"))
    }

    @Test("remove unlinks the file and forgets its verdict")
    func removeUnlinksAndForgets() throws {
        let file = try temporary.write(Data([0x01]), named: "model.gguf")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let key = try ModelVerifier.CacheKey(
            path: file.path,
            size: #require(attrs[.size] as? Int64),
            modified: #require(attrs[.modificationDate] as? Date)
        )
        let store = makeStore()
        store.record(key)
        #expect(store.contains(key), "the verdict starts recorded")

        try ModelRemoval.remove(.lite, at: file, verdicts: store)

        #expect(!FileManager.default.fileExists(atPath: file.path), "the file is gone")
        #expect(!store.contains(key), "a deleted file must not keep a verdict")
    }

    @Test("a failed unlink leaves the verdict in place")
    func failedUnlinkKeepsVerdict() throws {
        let missing = temporary.fileURL("missing.gguf")
        let store = makeStore()
        let key = ModelVerifier.CacheKey(path: missing.path, size: 1, modified: Date())
        store.record(key)

        #expect(throws: (any Error).self) {
            try ModelRemoval.remove(.lite, at: missing, verdicts: store)
        }

        #expect(store.contains(key), "a failed unlink must not forget a file that still exists")
    }
}
