import Foundation

/// Resolves the ASR GGUF for a chosen `ASRModelChoice` in priority order:
///   1. Bundled: `Bundle.main` → `models/` (downloader skipped)
///   2. Downloaded: `~/Library/Application Support/Mimidasu/models/`
///   3. Dev checkout: `<cwd>/models/` (DEBUG only)
/// Both choices live side-by-side in the shared models directory.
enum ModelLocator {
    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mimidasu/models", isDirectory: true)
    }

    static func bundledURL(for choice: ASRModelChoice) -> URL? {
        Bundle.main.url(forResource: choice.ggufFileName, withExtension: nil, subdirectory: "models")
            ?? Bundle.main.url(forResource: choice.ggufFileName, withExtension: nil)
    }

    static func downloadedURL(for choice: ASRModelChoice) -> URL {
        modelsDirectory.appendingPathComponent(choice.ggufFileName)
    }

    /// Development checkout candidate: the dev GGUF is downloaded manually
    /// into <repo>/models/; Xcode runs the app with that as working
    /// directory. Debug-only so release never depends on the cwd.
    static func devCheckoutURL(for choice: ASRModelChoice) -> URL? {
        #if DEBUG
            return URL(fileURLWithPath: "models/\(choice.ggufFileName)")
        #else
            return nil
        #endif
    }

    /// Resolve the model for a session; nil means the onboarding/downloader
    /// must run first (or the user drops a GGUF in manually). Candidates,
    /// existence, and verification are injectable so tests can pin the
    /// search order without touching the real model locations; the defaults
    /// drive the bundled → downloaded → dev lookup.
    static func resolve(
        for choice: ASRModelChoice,
        bundled: (ASRModelChoice) -> URL? = { choice in ModelLocator.bundledURL(for: choice) },
        downloaded: (ASRModelChoice) -> URL = { choice in ModelLocator.downloadedURL(for: choice) },
        dev: (ASRModelChoice) -> URL? = { choice in ModelLocator.devCheckoutURL(for: choice) },
        fileExists: (String) -> Bool = { path in FileManager.default.fileExists(atPath: path) },
        isVerified: (URL, ASRModelChoice) -> Bool = { url, choice in
            ModelVerifier.isVerified(url, for: choice)
        }
    ) -> URL? {
        if let bundledURL = bundled(choice), isVerified(bundledURL, choice) {
            return bundledURL
        }
        let downloadedURL = downloaded(choice)
        if fileExists(downloadedURL.path), isVerified(downloadedURL, choice) {
            return downloadedURL
        }
        if let devURL = dev(choice), fileExists(devURL.path), isVerified(devURL, choice) {
            return devURL
        }
        return nil
    }
}
