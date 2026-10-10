import Foundation
@testable import Mimidasu

/// Installs the repo's prepared JMDict database into the Application Support
/// destination `DictionaryStore` promotes into, once, when it is missing.
///
/// The test host's working directory is not the repo root, so the store's
/// debug-checkout fallback never resolves in tests — without this install,
/// any code path taking `ensureDictionaryReady`'s real default closures
/// (the session-flow suite's `start()`) would attempt a bundled-decompress
/// of an app-bundle resource the test build does not ship and fail the
/// start. nil when the repo artifact is unavailable — consumers disable
/// themselves.
///
/// The install is the same promote the store performs (plain copy into the
/// default destination), so the app's real library directory only ever
/// gains the exact file a first launch would produce.
///
/// It copies the **dev artifact**, which carries the gloss index, rather than
/// the raw ingestion output. The gloss stage has no `LIKE` fallback, so an
/// index-less database answers every Latin query with zero rows — and that
/// looks exactly like a database with no English glosses, which is the kind of
/// failure a test suite reports as a pass. When only the raw artifact exists
/// the index is built onto the copy, since building it is what a first launch
/// does anyway.
///
/// "Carries the index" means an index the store would actually **adopt**: the
/// same `JMDictFTSIndex.isPresent` check the app makes, so a destination left
/// behind by an older index schema is re-staged here exactly as a first launch
/// would re-stage it. Returning nil instead would disable every live-gated
/// suite silently — a gate that passes without executing is worse than a red
/// one.
enum InstalledJMDict {
    static let url: URL? = {
        let destination = DictionaryStore.defaultJMDictURL
        if FileManager.default.fileExists(atPath: destination.path),
           JMDictFTSIndex.isPresent(at: destination)
        {
            return destination
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dev = repoRoot.appendingPathComponent(JMDictPin.debugCheckoutPath)
        let raw = repoRoot.appendingPathComponent("build/\(JMDictPin.preparedFileName)")
        guard FileManager.default.fileExists(atPath: dev.path)
            || FileManager.default.fileExists(atPath: raw.path)
        else { return nil }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(
                at: FileManager.default.fileExists(atPath: dev.path) ? dev : raw,
                to: destination
            )
            if !JMDictFTSIndex.isPresent(at: destination) {
                try JMDictFTSIndex.build(at: destination)
            }
            guard JMDictFTSIndex.isPresent(at: destination) else { return nil }
        } catch {
            return nil
        }
        return destination
    }()
}
