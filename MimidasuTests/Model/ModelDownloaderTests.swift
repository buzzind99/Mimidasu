import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests `ModelDownloader` state transitions by invoking the
/// `URLSessionDownloadDelegate` callbacks directly (no network). `begin()`'s
/// file arms run over injected transports — a temp destination plus a no-op
/// or suspended task factory, so nothing touches the network or the real
/// installed model. The live download path — the resume-data arm, a real
/// transfer in flight, and the session/task wiring against HuggingFace —
/// needs a real HuggingFace transfer and stays excluded. The
/// `didFinishDownloadingTo` success path uses a clone of the repo's dev GGUF
/// (digest matches the pin; skipped when absent) and moves it to an injected
/// temporary destination. Verdict stores are injected too, so no test writes
/// to the production `VerdictStore.shared` cache.
@MainActor
@Suite("ModelDownloader")
struct ModelDownloaderTests {

    private let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory(prefix: "mimidasu-download")
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

    /// A transport whose task factory never starts network work: `begin()`
    /// runs its file-side effects and stops before any transfer.
    private func makeOfflineTransport(
        destination: URL,
        verdictStore: ModelVerifier.VerdictStore,
        makeTask: @escaping (URLSession) -> URLSessionDownloadTask? = { _ in nil }
    ) -> ModelDownloader {
        ModelDownloader(
            destination: destination,
            verdictStore: verdictStore,
            makeSession: { _ in URLSession(configuration: .ephemeral) },
            makeTask: makeTask
        )
    }

    // MARK: - cancel

    @Test("cancel while idle is a no-op that republishes nothing")
    func cancelWhileIdle() async {
        let downloader = ModelDownloader()
        let emissions = ObservedValuesRecorder(read: { downloader.state })

        downloader.cancel()
        downloader.cancel()
        await flushObservations()

        #expect(emissions.values.isEmpty, "idle cancel must not republish .idle")
    }

    // MARK: - start

    /// The downloader derives its destination and download URL from the
    /// choice it was constructed with, and an injected destination overrides
    /// the choice-derived one.
    @Test("destination and download URL derive from the choice")
    func perChoiceURLDerivation() {
        for choice in ASRModelChoice.allCases {
            let downloader = ModelDownloader(choice: choice)

            #expect(downloader.destination == ModelLocator.downloadedURL(for: choice))
            #expect(ModelDownloader.downloadURL(for: choice) == choice.downloadURL)
        }
        // An injected destination (test seam) overrides the choice-derived one.
        let injected = URL(fileURLWithPath: "/tmp/injected.gguf")
        #expect(
            ModelDownloader(choice: .full, destination: injected).destination == injected
        )
    }

    @Test(
        "start finishes done for an already-verified model and ignores further starts",
        .enabled(if: ModelVerifier.isVerified(
            ModelLocator.downloadedURL(for: .lite), for: .lite, store: .sharedReadOnly
        ))
    )
    func startWhenVerifiedModelAlreadyPresent() async {
        let destination = ModelLocator.downloadedURL(for: .lite)
        let downloader = ModelDownloader(verdictStore: .sharedReadOnly)

        downloader.start()
        #expect(
            await pollUntil(timeout: 30) {
                if case .done = downloader.state {
                    return true
                }
                return false
            },
            "state should reach .done via the already-verified-model arm"
        )
        #expect(downloader.state == .done(destination))

        let emissions = ObservedValuesRecorder(read: { downloader.state })
        downloader.start()
        await flushObservations()

        #expect(emissions.values.isEmpty, "start() once .done must be a no-op")
    }

    @Test(
        "start finishes done for a verified file at the destination",
        .enabled(if: TestEnvironment.repoDevModelInstalled)
    )
    func startWithVerifiedDestinationFinishesDone() async throws {
        let file = try #require(try ModelTestFixtures.cloneRepoModel())
        let downloader = makeOfflineTransport(destination: file, verdictStore: makeStore())

        downloader.start()
        #expect(
            await pollUntil(timeout: 30) {
                if case .done = downloader.state {
                    return true
                }
                return false
            },
            "state should reach .done via the already-verified-model arm"
        )
        #expect(downloader.state == .done(file))
    }

    @Test("start removes an unverified file at the destination and creates the download task")
    func startRemovesUnverifiedDestination() async throws {
        let file = try temporary.write(Data([0x00, 0x01, 0x02]), named: ASRModelChoice.lite.ggufFileName)
        let createdTasks = Mutex(0)
        let downloader = makeOfflineTransport(destination: file, verdictStore: makeStore()) { _ in
            createdTasks.withLock { count in count += 1 }
            return nil
        }

        downloader.start()
        #expect(
            await pollUntil(timeout: 5) {
                if case .downloading = downloader.state {
                    return true
                }
                return false
            },
            "state should reach .downloading after clearing the bad file"
        )
        #expect(downloader.state == .downloading(progress: 0, bytes: 0, total: nil))
        #expect(!FileManager.default.fileExists(atPath: file.path), "an unverifiable destination is removed")
        #expect(createdTasks.withLock { count in count } == 1, "the download task is created after clearing")

        let emissions = ObservedValuesRecorder(read: { downloader.state })
        downloader.start()
        await flushObservations()

        #expect(emissions.values.isEmpty, "a second start while already downloading is a no-op")
    }

    @Test("cancel while a task is in flight returns to idle without a failure")
    func cancelWhileTaskInFlight() async throws {
        let url = try #require(URL(string: "https://example.invalid/mimidasu-test.gguf"))
        let downloader = ModelDownloader(
            destination: temporary.fileURL("in-flight.gguf"),
            makeSession: { _ in URLSession(configuration: .ephemeral) },
            makeTask: { session in
                let task = session.downloadTask(with: url)
                // Suspend twice: begin()'s resume() consumes one suspension,
                // leaving the task suspended so no network ever starts. A
                // single suspend would let the task run and race cancel()
                // against a real DNS failure for the invalid host.
                task.suspend()
                task.suspend()
                return task
            }
        )
        let emissions = ObservedValuesRecorder(read: { downloader.state })

        downloader.start()
        #expect(
            await pollUntil(timeout: 5) {
                if case .downloading = downloader.state {
                    return true
                }
                return false
            }
        )
        downloader.cancel()
        #expect(
            await pollUntil(timeout: 5) {
                if case .idle = downloader.state {
                    return true
                }
                return false
            },
            "cancel() publishes the idle state"
        )
        #expect(downloader.state == .idle)
        // The .idle emission is recorded via a main-actor hop; gate on it.
        #expect(await pollUntil { emissions.values.last == .idle })
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

    @Test("a restart republishes the remembered expected total")
    func restartRepublishesRememberedTotal() async throws {
        let downloader = makeOfflineTransport(
            destination: temporary.fileURL("restart.gguf"), verdictStore: makeStore()
        )
        let task = try makeDownloadTask()

        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 100, totalBytesWritten: 100, totalBytesExpectedToWrite: 1000
        )
        #expect(
            await pollUntil { downloader.state == .downloading(progress: 0.1, bytes: 100, total: 1000) },
            "the delegate remembers the expected total"
        )

        downloader.start()
        #expect(
            await pollUntil {
                downloader.state == .downloading(progress: 0, bytes: 0, total: 1000)
            },
            "the restart republishes the remembered total, not nil"
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

    @Test("default construction derives the .lite destination from the default choice")
    func defaultConstruction() {
        let downloader = ModelDownloader()

        #expect(downloader.destination == ModelLocator.downloadedURL(for: .lite))
    }
}
