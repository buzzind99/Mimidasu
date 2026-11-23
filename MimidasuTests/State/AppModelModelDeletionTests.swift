import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests `AppModel`'s model-delete command over a scratch models directory:
/// the refusal rules, the failed-unlink behaviour, and the stale-map
/// hardening. The map is built by a stubbed resolver, so no test touches
/// Application Support or hashes a real GGUF.
@MainActor
@Suite("AppModel model deletion")
struct AppModelModelDeletionTests {

    @Test("a delete is refused for the last installed model")
    func deleteRefusesLastInstalledModel() async throws {
        let temporary = try TemporaryDirectory()
        let liteURL = try install(.lite, in: temporary)
        let removals = CallLog()
        let model = await makeDeletionModel(
            resolve: { choice in choice == .lite ? liteURL : nil },
            directory: temporary.url,
            modelRemove: removingFiles(in: temporary.url, loggedBy: removals)
        )
        model.phase = .idle

        let deleted = await model.deleteDownloadedModel(.lite)

        #expect(!deleted)
        #expect(removals.names.isEmpty)
        #expect(model.modelAvailability == [.lite: liteURL])
        #expect(model.asrModelSettings.selected == .lite)
    }

    @Test("a delete is refused while the session is live or stopping")
    func deleteRefusesLiveOrStopping() async throws {
        let temporary = try TemporaryDirectory()
        try install(.lite, in: temporary)
        try install(.haas, in: temporary)
        let removals = CallLog()
        let model = await makeDeletionModel(
            resolve: installedResolver(in: temporary.url),
            directory: temporary.url,
            modelRemove: removingFiles(in: temporary.url, loggedBy: removals)
        )

        for phase in [
            SessionPhase.starting, .running, .sourceLost, .paused, .stopping
        ] {
            model.phase = phase

            let deleted = await model.deleteDownloadedModel(.haas)

            #expect(!deleted, "the delete must be refused while \(phase)")
            #expect(removals.names.isEmpty, "nothing may be removed while \(phase)")
        }
    }

    @Test("a delete is refused for a model the app did not download")
    func deleteRefusesForeignModel() async throws {
        let temporary = try TemporaryDirectory()
        let externalDirectory = temporary.url
            .deletingLastPathComponent()
            .appendingPathComponent("mimidasu-external", isDirectory: true)
        let liteURL = externalDirectory.appendingPathComponent(ASRModelChoice.lite.ggufFileName)
        let haasURL = externalDirectory.appendingPathComponent(ASRModelChoice.haas.ggufFileName)
        let removals = CallLog()
        let model = await makeDeletionModel(
            resolve: { choice in
                switch choice {
                case .lite: liteURL
                case .haas: haasURL
                case .full: nil
                }
            },
            directory: temporary.url,
            modelRemove: removingFiles(in: temporary.url, loggedBy: removals)
        )
        model.phase = .idle

        let deleted = await model.deleteDownloadedModel(.lite)

        #expect(!deleted)
        #expect(removals.names.isEmpty)
        #expect(model.modelAvailability == [.lite: liteURL, .haas: haasURL])
    }

    @Test("a failing unlink warns and changes nothing")
    func deleteFailureKeepsModelAndSelection() async throws {
        let temporary = try TemporaryDirectory()
        let liteURL = try install(.lite, in: temporary)
        let haasURL = try install(.haas, in: temporary)
        let removals = CallLog()
        let model = await makeDeletionModel(
            resolve: installedResolver(in: temporary.url),
            directory: temporary.url,
            modelRemove: { choice in
                removals.record(choice.rawValue)
                throw RemovalFailure()
            }
        )
        model.phase = .idle

        let deleted = await model.deleteDownloadedModel(.haas)

        #expect(!deleted)
        #expect(removals.names == [ASRModelChoice.haas.rawValue])
        #expect(model.modelAvailability == [.lite: liteURL, .haas: haasURL])
        #expect(model.asrModelSettings.selected == .lite)
        #expect(model.modelURL == liteURL)
        let deleteToasts = model.toasts.toasts.filter { toast in
            toast.key == ToastKey.modelDelete
        }
        #expect(deleteToasts.count == 1)
        let failure = try #require(deleteToasts.first)
        #expect(failure.style == .yellowAuto)
        #expect(failure.title == "Couldn't delete Balanced model")
        #expect(failure.body.hasPrefix("The model is still installed. "))
        #expect(failure.isClosable, "the failure card can be dismissed")
        #expect(!deleteToasts.contains { toast in toast.style == .info })
    }

    @Test("a failing unlink on the selected model never hands over")
    func deleteSelectedFailureKeepsSelection() async throws {
        let temporary = try TemporaryDirectory()
        let liteURL = try install(.lite, in: temporary)
        let haasURL = try install(.haas, in: temporary)
        let removals = CallLog()
        let model = await makeDeletionModel(
            resolve: installedResolver(in: temporary.url),
            directory: temporary.url,
            modelRemove: { choice in
                removals.record(choice.rawValue)
                throw RemovalFailure()
            }
        )
        model.phase = .idle

        let deleted = await model.deleteDownloadedModel(.lite)

        #expect(!deleted)
        #expect(removals.names == [ASRModelChoice.lite.rawValue])
        #expect(model.asrModelSettings.selected == .lite, "a failed unlink does not switch models")
        #expect(model.modelURL == liteURL)
        #expect(model.modelAvailability == [.lite: liteURL, .haas: haasURL])
        let deleteToasts = model.toasts.toasts.filter { toast in
            toast.key == ToastKey.modelDelete
        }
        #expect(deleteToasts.count == 1)
        let failure = try #require(deleteToasts.first)
        #expect(failure.style == .yellowAuto)
        #expect(failure.title == "Couldn't delete Lite model")
        #expect(!deleteToasts.contains { toast in toast.style == .info })
    }

    @Test("a model whose file vanished outside the app stops counting")
    func deleteRefusesWhenTheOtherModelFileIsGone() async throws {
        let temporary = try TemporaryDirectory()
        let directory = temporary.url
        let liteURL = try install(.lite, in: temporary)
        // In the map, but not on disk: the user deleted it in Finder and no
        // refresh has run since.
        let haasURL = directory.appendingPathComponent(ASRModelChoice.haas.ggufFileName)
        let removals = CallLog()
        let model = await makeDeletionModel(
            resolve: { choice in
                switch choice {
                case .lite: liteURL
                case .haas: haasURL
                case .full: nil
                }
            },
            directory: directory,
            modelRemove: removingFiles(in: directory, loggedBy: removals)
        )

        for phase in [SessionPhase.idle, .failed("boom")] {
            model.phase = phase

            let deleted = await model.deleteDownloadedModel(.lite)

            #expect(!deleted, "only one real model file is left, so the delete is refused")
            #expect(removals.names.isEmpty)
            #expect(model.modelAvailability[.lite] == liteURL)
            #expect(model.asrModelSettings.selected == .lite)
            #expect(model.modelURL == liteURL)
        }
    }
}

/// Tests the delete command's successful paths: the selected model's
/// hand-over, a non-selected delete's silence, and the discard of an
/// availability pass that snapshotted the disk before the unlink.
@MainActor
@Suite("AppModel model deletion hand-over")
struct AppModelModelDeletionHandoverTests {

    @Test("deleting the selected model hands over to the first remaining model")
    func deleteSelectedModelHandsOver() async throws {
        let temporary = try TemporaryDirectory()
        try install(.lite, in: temporary)
        let haasURL = try install(.haas, in: temporary)
        try install(.full, in: temporary)
        let removals = CallLog()
        let resolves = CallLog()
        let base = installedResolver(in: temporary.url)
        let model = await makeDeletionModel(
            resolve: { choice in
                resolves.record(choice.rawValue)
                return base(choice)
            },
            directory: temporary.url,
            modelRemove: removingFiles(in: temporary.url, loggedBy: removals)
        )
        model.phase = .idle
        let phases = ObservedValuesRecorder(read: { model.phase })
        let resolvesBefore = resolves.names.count

        let deleted = await model.deleteDownloadedModel(.lite)
        await flushObservations()

        #expect(deleted)
        #expect(removals.names == [ASRModelChoice.lite.rawValue])
        #expect(model.asrModelSettings.selected == .haas)
        #expect(model.modelURL == haasURL)
        #expect(model.modelAvailability[.lite] == nil)
        #expect(model.phase == .idle)
        #expect(!phases.values.contains(.needsModel), "the hand-over must never need a model")
        #expect(
            resolves.names.count - resolvesBefore == ASRModelChoice.allCases.count,
            "the hand-over runs exactly one availability refresh"
        )
        let deleteToasts = model.toasts.toasts.filter { toast in
            toast.key == ToastKey.modelDelete
        }
        #expect(deleteToasts.count == 1)
        let success = try #require(deleteToasts.first)
        #expect(success.style == .info)
        #expect(success.title == "Deleted Lite model")
        #expect(success.body == "Switched to Balanced.")
    }

    @Test("deleting a non-selected model leaves the selection and the resolver alone")
    func deleteNonSelectedModelKeepsSelection() async throws {
        let temporary = try TemporaryDirectory()
        let directory = temporary.url
        let liteURL = try install(.lite, in: temporary)
        let haasURL = try install(.haas, in: temporary)
        try install(.full, in: temporary)
        let removals = CallLog()
        let resolves = CallLog()
        let model = await makeDeletionModel(
            resolve: { choice in
                resolves.record(choice.rawValue)
                return installedResolver(in: directory)(choice)
            },
            directory: directory,
            modelRemove: removingFiles(in: directory, loggedBy: removals)
        )
        model.phase = .idle
        let resolvesBefore = resolves.names.count

        let deleted = await model.deleteDownloadedModel(.full)

        #expect(deleted)
        #expect(removals.names == [ASRModelChoice.full.rawValue])
        #expect(model.modelAvailability[.full] == nil)
        #expect(model.modelAvailability[.lite] == liteURL)
        #expect(model.modelAvailability[.haas] == haasURL)
        #expect(model.asrModelSettings.selected == .lite)
        #expect(model.modelURL == liteURL)
        #expect(resolves.names.count == resolvesBefore, "a non-selected delete must not refresh")
        #expect(
            !model.toasts.toasts.contains { toast in toast.key == ToastKey.modelDelete },
            "a plain delete is silent — the card flipping is the feedback"
        )
    }

    @Test("a pass that started before the delete cannot republish the deleted model")
    func deleteDropsAStaleAvailabilityPass() async throws {
        let temporary = try TemporaryDirectory()
        let directory = temporary.url
        try install(.lite, in: temporary)
        let haasURL = try install(.haas, in: temporary)
        try install(.full, in: temporary)
        let model = await makeDeletionModel(
            resolve: installedResolver(in: directory),
            directory: directory,
            modelRemove: removingFiles(in: directory, loggedBy: CallLog())
        )
        model.phase = .idle

        // The pass snapshots the pre-delete map but finishes only after the
        // delete released it — an untracked pass, so the delete cannot await it.
        let released = Mutex(false)
        let staleResolver: @Sendable (ASRModelChoice) -> URL? = { choice in
            if choice == .lite {
                var spins = 0
                while !released.withLock({ flag in flag }), spins < 600 {
                    Thread.sleep(forTimeInterval: 0.005)
                    spins += 1
                }
            }
            return directory.appendingPathComponent(choice.ggufFileName)
        }
        let stalePass = Task { await model.refreshModelAvailability(resolve: staleResolver) }
        #expect(await pollUntil { model.isCheckingModel }, "the stale pass is in flight")

        let deleted = await model.deleteDownloadedModel(.lite)
        released.withLock { flag in flag = true }
        await stalePass.value

        #expect(deleted)
        #expect(
            model.modelAvailability[.lite] == nil,
            "a snapshot computed before the unlink must not resurrect the entry"
        )
        #expect(model.modelURL == haasURL)
        #expect(model.phase == .idle)
        #expect(!model.isCheckingModel, "a discarded pass still clears the Start gate")
    }

    @Test("a non-selected delete keeps a concurrent pass's new discovery")
    func deleteKeepsAConcurrentPassDiscovery() async throws {
        let temporary = try TemporaryDirectory()
        let directory = temporary.url
        let liteURL = try install(.lite, in: temporary)
        try install(.haas, in: temporary)
        // Full is downloaded but no pass has listed it yet.
        let fullURL = try install(.full, in: temporary)
        let model = await makeDeletionModel(
            resolve: { choice in
                guard choice != .full else { return nil }
                let url = directory.appendingPathComponent(choice.ggufFileName)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            },
            directory: directory,
            modelRemove: removingFiles(in: directory, loggedBy: CallLog())
        )
        model.phase = .idle

        // The pass resolves all three files (including the deleted model's old
        // path) but finishes only after the delete released it.
        let released = Mutex(false)
        let staleResolver: @Sendable (ASRModelChoice) -> URL? = { choice in
            if choice == .haas {
                var spins = 0
                while !released.withLock({ flag in flag }), spins < 600 {
                    Thread.sleep(forTimeInterval: 0.005)
                    spins += 1
                }
            }
            return directory.appendingPathComponent(choice.ggufFileName)
        }
        let stalePass = Task { await model.refreshModelAvailability(resolve: staleResolver) }
        #expect(await pollUntil { model.isCheckingModel }, "the pass is in flight")

        let deleted = await model.deleteDownloadedModel(.haas)
        released.withLock { flag in flag = true }
        await stalePass.value

        #expect(deleted)
        #expect(model.modelAvailability[.full] == fullURL, "the pass's discovery survives the delete")
        #expect(model.modelAvailability[.lite] == liteURL)
        #expect(model.modelAvailability[.haas] == nil, "the deleted model is not resurrected")
        #expect(model.asrModelSettings.selected == .lite)
        #expect(model.modelURL == liteURL)
        #expect(!model.isCheckingModel)
    }

    @Test("a restored file clears the delete tombstone")
    func deleteTombstoneClearsForARestoredFile() async throws {
        let temporary = try TemporaryDirectory()
        let directory = temporary.url
        try install(.lite, in: temporary)
        try install(.haas, in: temporary)
        let model = await makeDeletionModel(
            resolve: installedResolver(in: directory),
            directory: directory,
            modelRemove: removingFiles(in: directory, loggedBy: CallLog())
        )
        model.phase = .idle

        let deleted = await model.deleteDownloadedModel(.haas)
        #expect(deleted)
        #expect(model.modelAvailability[.haas] == nil)

        // A re-download (or a manually restored file) is a real model again,
        // not a stale snapshot: the tombstone must lift.
        let restored = try install(.haas, in: temporary)
        await model.refreshModelAvailability()

        #expect(model.modelAvailability[.haas] == restored)
        #expect(model.installedModels.contains(.haas), "the restored model counts again")
    }
}

// MARK: - Fixtures

/// An idle model whose model files live in `directory` and whose removals run
/// through the injected seam.
@MainActor
private func makeDeletionModel(
    resolve: @escaping @Sendable (ASRModelChoice) -> URL?,
    directory: URL,
    modelRemove: @escaping @Sendable (ASRModelChoice) throws -> Void
) async -> AppModel {
    let model = makeIdleModel(
        suite: "test.AppModelDeletion",
        initialModelResolve: resolve,
        modelFilesDirectory: directory,
        modelRemove: modelRemove
    )
    await model.initialModelCheck?.value
    return model
}

/// Writes an empty model file named for `choice` into the scratch directory
/// and returns its app-owned URL.
@discardableResult
private func install(
    _ choice: ASRModelChoice,
    in temporary: TemporaryDirectory
) throws -> URL {
    let url = temporary.url.appendingPathComponent(choice.ggufFileName)
    try Data().write(to: url)
    return url
}

/// Resolves a choice to its scratch-directory file only while that file still
/// exists, so a deleted model stops resolving.
private func installedResolver(
    in directory: URL
) -> @Sendable (ASRModelChoice) -> URL? {
    { choice in
        let url = directory.appendingPathComponent(choice.ggufFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// Records each removal and unlinks its file from the scratch directory.
private func removingFiles(
    in directory: URL,
    loggedBy log: CallLog
) -> @Sendable (ASRModelChoice) throws -> Void {
    { choice in
        log.record(choice.rawValue)
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(choice.ggufFileName)
        )
    }
}

private struct RemovalFailure: Error {}
