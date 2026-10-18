import Foundation
@testable import Mimidasu
import Testing

/// The stop-confirmation policy `AppModel.shouldConfirmStop`: a non-empty
/// transcript in a live-ish phase with a store that can persist the result
/// prompts; empty transcripts, cancel-during-start, stopping, idle-ish
/// phases, and an unavailable store stop directly. Pure policy — the alert
/// presentation is the window's (UI) side.
@MainActor
@Suite("AppModel stop confirmation")
struct AppModelStopConfirmationTests {

    private let livePhases: [SessionPhase] = [.running, .paused, .sourceLost]
    private let quietPhases: [SessionPhase] = [.needsModel, .idle, .starting, .stopping, .failed("boom")]

    private func makeModel(store: ArchiveStore = isolatedArchive()) -> AppModel {
        AppModel(favorites: isolatedFavorites(), archive: store)
    }

    private func entry(_ text: String) -> SessionEntry {
        SessionEntry(
            sentence: Sentence(index: 0, startS: 0, endS: 1.5, lang: "ja", text: text)
        )
    }

    @Test("a live-ish session with rows and a healthy store prompts")
    func liveNonEmptyPrompts() {
        let model = makeModel()
        model.entries = [entry("こんにちは")]

        for phase in livePhases {
            model.phase = phase
            #expect(model.shouldConfirmStop, "phase \(phase) must prompt")
        }
    }

    @Test("an empty transcript never prompts")
    func emptyTranscriptNeverPrompts() {
        let model = makeModel()
        model.entries = []

        for phase in livePhases {
            model.phase = phase
            #expect(!model.shouldConfirmStop)
        }
    }

    @Test("quiet phases never prompt even with rows")
    func quietPhasesNeverPrompt() {
        let model = makeModel()
        model.entries = [entry("こんにちは")]

        for phase in quietPhases {
            model.phase = phase
            #expect(!model.shouldConfirmStop, "phase \(phase) must stop directly")
        }
    }

    @Test("a latched write failure skips the prompt")
    func writeFailureSkipsPrompt() {
        let model = makeModel()
        model.entries = [entry("こんにちは")]
        model.phase = .running
        model.archiveWriteFailed = true

        #expect(!model.shouldConfirmStop)
    }

    @Test("a degraded store skips the prompt")
    func degradedStoreSkipsPrompt() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-stop-confirm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try? Data().write(to: blocker)
        let store = ArchiveStore(location: blocker.appendingPathComponent("archives.sqlite"))
        #expect(store.isDegraded)

        let model = makeModel(store: store)
        model.entries = [entry("こんにちは")]
        model.phase = .running

        #expect(!model.shouldConfirmStop)
        #expect(!model.archiveAvailable)
    }
}
