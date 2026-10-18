import Darwin
import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// An `ArchiveStore` over a private temp file. `ArchiveStore()` defaults to
/// the production Application Support location, so every `AppModel` built in
/// tests must go through this fixture — otherwise the suite opens (and
/// sweeps) the developer's real session archive. Unique per call, so parallel
/// tests never share a file; every root lives under one process-wide parent
/// directory, removed at process exit so the suite leaves nothing behind.
func isolatedArchive() -> ArchiveStore {
    let root = IsolatedArchiveFiles.makeRoot()
    return ArchiveStore(location: root.appendingPathComponent("archives.sqlite"))
}

/// The fixture's temp-file side: one lazy parent directory per test process
/// plus an exit sweep over the roots handed out under it. `ArchiveDatabase`
/// creates each root's directory tree on open, so registration only needs
/// the URL.
private enum IsolatedArchiveFiles {
    /// The shared parent; the first `isolatedArchive()` call creates it and
    /// registers the exit sweep with it.
    static let parent: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-isolated-archives-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = atexit(sweepIsolatedArchives)
        return directory
    }()

    /// Every root handed out this process. Swift Testing runs suites in
    /// parallel in one process, so registration races and takes the lock.
    private static let roots = Mutex<[URL]>([])

    /// A fresh root for one store, created under the shared parent.
    static func makeRoot() -> URL {
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        roots.withLock { registry in
            registry.append(root)
        }
        return root
    }

    /// Removes each registered root, then the parent that held them.
    static func sweep() {
        let registered = roots.withLock { registry in registry }
        for root in registered {
            try? FileManager.default.removeItem(at: root)
        }
        try? FileManager.default.removeItem(at: parent)
    }
}

/// The `atexit` handler: non-capturing, so it converts to a C function
/// pointer.
private func sweepIsolatedArchives() {
    IsolatedArchiveFiles.sweep()
}
