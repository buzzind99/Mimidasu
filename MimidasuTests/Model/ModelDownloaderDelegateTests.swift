import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests `ModelDownloader`'s `nonisolated` `URLSessionDownloadDelegate`
/// entry points by invoking them directly (no network): progress
/// throttling, digest verification on the temp file, and completion-error
/// handling. The live download path — the resume-data arm and a real
/// transfer in flight — needs a real HuggingFace transfer and stays
/// excluded. The success path clones the repo's dev GGUF (digest matches
/// the pin; skipped when absent). Verdict stores are injected, so no test
/// writes to the production `VerdictStore.shared` cache.
@MainActor
@Suite("ModelDownloader delegate callbacks")
struct ModelDownloaderDelegateTests {

    private let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory(prefix: "mimidasu-download-delegate")
    }

    // MARK: - Helpers

    private func makeDownloadTask() throws -> URLSessionDownloadTask {
        let url = try #require(URL(string: "https://example.invalid/mimidasu-test.gguf"))
        return URLSession.shared.downloadTask(with: url)
    }

    /// A fresh verdict store at a temporary URL (never the shared one).
    private func makeStore(_ name: String = "verdicts.json") -> ModelVerifier.VerdictStore {
        ModelVerifier.VerdictStore(url: temporary.fileURL(name))
    }

    // MARK: - didWriteData

    @Test("didWriteData publishes fractional progress for a known total")
    func didWriteDataPublishesFractionalProgress() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 250, totalBytesWritten: 250, totalBytesExpectedToWrite: 1000
        )
        #expect(
            await pollUntil { downloader.state == .downloading(progress: 0.25, bytes: 250, total: 1000) }
        )
    }

    @Test("didWriteData publishes zero progress and nil total for an unknown total")
    func didWriteDataPublishesZeroProgressForUnknownTotal() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 100, totalBytesWritten: 300, totalBytesExpectedToWrite: 0
        )
        #expect(
            await pollUntil { downloader.state == .downloading(progress: 0, bytes: 300, total: nil) }
        )
    }

    @Test("didWriteData throttles a sub-0.5% progress delta within the publish interval")
    func didWriteDataThrottlesSmallDeltas() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        // First callback always publishes (0.25 ≥ the delta threshold from
        // the -1 seed); the second (0.251, +0.1%) is throttled.
        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 250, totalBytesWritten: 250, totalBytesExpectedToWrite: 1000
        )
        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 1, totalBytesWritten: 251, totalBytesExpectedToWrite: 1000
        )
        #expect(
            await pollUntil { downloader.state == .downloading(progress: 0.25, bytes: 250, total: 1000) }
        )
    }

    @Test("didWriteData republishes after the publish interval despite a sub-threshold delta")
    func didWriteDataRepublishesAfterPublishInterval() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 250, totalBytesWritten: 250, totalBytesExpectedToWrite: 1000
        )
        #expect(
            await pollUntil { downloader.state == .downloading(progress: 0.25, bytes: 250, total: 1000) },
            "the first publish seeds the interval clock"
        )

        try await Task.sleep(for: .milliseconds(200))
        // Same +0.1% delta as the throttle test, but past the 100 ms publish
        // interval, so the time arm (not the delta arm) republishes.
        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 1, totalBytesWritten: 251, totalBytesExpectedToWrite: 1000
        )
        #expect(
            await pollUntil { downloader.state == .downloading(progress: 0.251, bytes: 251, total: 1000) }
        )
    }

    // MARK: - didFinishDownloadingTo

    @Test("didFinishDownloadingTo fails on a digest mismatch and removes the temp file")
    func didFinishDownloadingToDigestMismatch() async throws {
        let downloader = ModelDownloader()
        let tempFile = try temporary.write(Data([0x01, 0x02, 0x03]), named: "bad-digest.gguf")
        let task = try makeDownloadTask()
        let destination = ModelLocator.downloadedURL(for: .lite)
        let destinationExisted = FileManager.default.fileExists(atPath: destination.path)
        let mismatch = ModelVerifier.VerificationError(message: ModelVerifier.checksumMismatchMessage)

        downloader.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: tempFile)
        #expect(
            await pollUntil {
                downloader.state == .failed(ModelDownloader.verificationFailureMessage(mismatch))
            }
        )
        #expect(!FileManager.default.fileExists(atPath: tempFile.path), "temp file must be removed")
        #expect(
            FileManager.default.fileExists(atPath: destination.path) == destinationExisted,
            "a failed verification must never touch the model destination"
        )
    }

    @Test(
        "didFinishDownloadingTo moves a digest-matching file into place and finishes",
        .enabled(if: TestEnvironment.repoDevModelInstalled)
    )
    func didFinishDownloadingToDigestMatch() async throws {
        let tempFile = try #require(try ModelTestFixtures.cloneRepoModel())
        let destination = temporary.fileURL("installed.gguf")
        let downloader = ModelDownloader(destination: destination, verdictStore: makeStore())
        let task = try makeDownloadTask()

        downloader.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: tempFile)
        #expect(
            await pollUntil(timeout: 30) {
                if case .done = downloader.state {
                    return true
                }
                return false
            },
            "state should reach .done after verification and move"
        )
        #expect(downloader.state == .done(destination))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: tempFile.path), "temp file is consumed by the move")
    }

    // MARK: - didCompleteWithError

    @Test("didCompleteWithError with a nil error stays idle")
    func didCompleteWithErrorNilStaysIdle() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(.shared, task: task, didCompleteWithError: nil)
        await flushObservations()

        #expect(downloader.state == .idle, "success is handled by didFinishDownloadingTo")
    }

    @Test("didCompleteWithError with a cancelled error stays idle")
    func didCompleteWithErrorCancelledStaysIdle() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        downloader.urlSession(.shared, task: task, didCompleteWithError: error)
        await flushObservations()

        #expect(downloader.state == .idle, "cancel() already published the idle state")
    }

    @Test("didCompleteWithError with a failure publishes the failed message")
    func didCompleteWithErrorPublishesFailure() async throws {
        let downloader = ModelDownloader()
        let task = try makeDownloadTask()
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "offline"]
        )

        downloader.urlSession(.shared, task: task, didCompleteWithError: error)
        #expect(
            await pollUntil {
                downloader.state == .failed(ModelDownloader.downloadFailureMessage(error))
            }
        )
    }
}
