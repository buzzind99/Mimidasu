import Foundation
@testable import Mimidasu
import Testing

/// An `ArchiveStore` over a private temp file. `ArchiveStore()` defaults to
/// the production Application Support location, so every `AppModel` built in
/// tests must go through this fixture — otherwise the suite opens (and
/// sweeps) the developer's real session archive. Unique per call, so parallel
/// tests never share a file; the files live in the temporary directory, which
/// the OS reclaims.
func isolatedArchive() -> ArchiveStore {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimidasu-archive-\(UUID().uuidString)", isDirectory: true)
    return ArchiveStore(location: root.appendingPathComponent("archives.sqlite"))
}
