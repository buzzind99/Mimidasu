import Foundation

/// The models the app itself downloaded: which of them exist, which one takes
/// over when one is deleted, and whether a delete is allowed. Pure over the
/// availability map the model-selection surface publishes — a choice counts
/// only when its resolved file sits in the app's models directory, so a
/// bundled or checkout copy of the same GGUF neither counts nor becomes
/// deletable.
enum ModelInventory {
    /// The app-owned installed choices, in picker order.
    static func installed(
        in availability: [ASRModelChoice: URL],
        modelsDirectory: URL
    ) -> [ASRModelChoice] {
        ASRModelChoice.allCases.filter { choice in
            guard let url = availability[choice] else { return false }
            return isAppOwned(url, modelsDirectory: modelsDirectory)
        }
    }

    /// True when the file lives directly in the app's models directory —
    /// i.e. the app may unlink it.
    static func isAppOwned(_ url: URL, modelsDirectory: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL
            == modelsDirectory.standardizedFileURL
    }

    /// The choice that takes over when `deleted` goes, or nil when nothing
    /// else is installed.
    static func replacement(
        deleting deleted: ASRModelChoice,
        installed: [ASRModelChoice]
    ) -> ASRModelChoice? {
        installed.first { choice in choice != deleted }
    }

    /// The whole "can this be deleted" rule.
    static func canDelete(
        _ choice: ASRModelChoice,
        installed: [ASRModelChoice],
        isLiveOrStopping: Bool
    ) -> Bool {
        guard installed.count > 1, installed.contains(choice) else { return false }
        return !isLiveOrStopping
    }
}

/// The one way a downloaded model file goes away.
enum ModelRemoval {
    /// Unlinks the choice's downloaded file, then forgets its verification
    /// verdict. A failed unlink throws before the verdict is touched, so only
    /// a delete that actually removed the file drops its cache entry.
    static func remove(
        _ choice: ASRModelChoice,
        at url: URL? = nil,
        verdicts: ModelVerifier.VerdictStore = .shared
    ) throws {
        let target = url ?? ModelLocator.downloadedURL(for: choice)
        try FileManager.default.removeItem(at: target)
        verdicts.forget(path: target.path)
    }
}
