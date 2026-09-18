import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests `ModelDownloader`'s start/cancel lifecycle over injected
/// transports — a temp destination plus a no-op or suspended task factory,
/// so nothing touches the network or the real installed model. The live
/// download path — the resume-data arm, a real transfer in flight, and the
/// session/task wiring against HuggingFace — needs a real HuggingFace
/// transfer and stays excluded. The already-verified arms use a clone of
/// the repo's dev GGUF or a recorded verdict (skipped via `.enabled(if:)`
/// when the fixture is absent — see `ModelTestFixtures`). Delegate-callback
/// behavior (progress, verification, completion) lives in
/// `ModelDownloaderDelegateTests`. Verdict stores are injected, so no test
/// writes to the production `VerdictStore.shared` cache.
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

    /// A recorded verdict lets `begin()` finish done for a file the pin
    /// cannot match — the persisted store is trusted without a re-hash — so
    /// the already-done short-circuit in `start()` runs offline.
    @Test("start after done is a no-op via the persisted-verdict arm")
    func startWhenAlreadyDoneIsNoOp() async throws {
        let file = try temporary.write(Data([0x00]), named: "installed.gguf")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let key = try ModelVerifier.CacheKey(
            path: file.path,
            size: #require(attrs[.size] as? Int64),
            modified: #require(attrs[.modificationDate] as? Date)
        )
        let store = makeStore()
        store.record(key)

        let downloader = makeOfflineTransport(destination: file, verdictStore: store)
        downloader.start()
        #expect(
            await pollUntil(timeout: 5) {
                if case .done = downloader.state {
                    return true
                }
                return false
            },
            "the recorded verdict finishes done without a re-hash"
        )

        let emissions = ObservedValuesRecorder(read: { downloader.state })
        downloader.start()
        await flushObservations()

        #expect(emissions.values.isEmpty, "start() once .done must be a no-op")
    }

    /// Omitting the session factory exercises the production default: a real
    /// `URLSession` wired to the downloader. The nil task keeps the transfer
    /// from ever starting.
    @Test("the default session factory runs begin() over a real session without a transfer")
    func defaultSessionFactoryRunsBeginWithoutNetwork() async {
        let downloader = ModelDownloader(
            destination: temporary.fileURL("default-session.gguf"),
            verdictStore: makeStore(),
            makeTask: { _ in nil }
        )

        downloader.start()
        #expect(
            await pollUntil(timeout: 5) {
                if case .downloading = downloader.state {
                    return true
                }
                return false
            },
            "begin() runs over the production default session with a nil task"
        )
        #expect(downloader.state == .downloading(progress: 0, bytes: 0, total: nil))
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

    // MARK: - default construction

    @Test("default construction derives the .lite destination from the default choice")
    func defaultConstruction() {
        let downloader = ModelDownloader()

        #expect(downloader.destination == ModelLocator.downloadedURL(for: .lite))
    }
}
