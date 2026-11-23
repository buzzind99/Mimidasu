import Foundation
@testable import Mimidasu
import Testing

/// The pure inventory rules: which downloaded models count as app-owned, which
/// one takes over when another is deleted, and when a deletion is allowed.
/// The URLs are scratch paths under a temporary directory — the rules
/// themselves never touch the file system.
@Suite("Model inventory")
struct ModelInventoryTests {

    private let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory(prefix: "mimidasu-inventory")
    }

    // MARK: - installed

    @Test("installed returns app-owned entries in picker order regardless of dictionary order")
    func installedKeepsPickerOrder() {
        let directory = temporary.url
        let availability: [ASRModelChoice: URL] = [
            .full: directory.appendingPathComponent("full.gguf"),
            .lite: directory.appendingPathComponent("lite.gguf"),
            .haas: directory.appendingPathComponent("haas.gguf")
        ]

        #expect(
            ModelInventory.installed(in: availability, modelsDirectory: directory)
                == [.lite, .haas, .full]
        )
    }

    @Test("installed drops entries whose file is not directly in the models directory")
    func installedDropsOutsideEntries() {
        let directory = temporary.url
        let availability: [ASRModelChoice: URL] = [
            .lite: directory.appendingPathComponent("lite.gguf"),
            .haas: directory.appendingPathComponent("sub").appendingPathComponent("haas.gguf"),
            .full: directory.deletingLastPathComponent().appendingPathComponent("full.gguf")
        ]

        #expect(
            ModelInventory.installed(in: availability, modelsDirectory: directory) == [.lite],
            "a nested or sibling file is not app-owned"
        )
    }

    // MARK: - isAppOwned

    @Test("isAppOwned accepts only a file directly in the models directory")
    func isAppOwnedAcceptsOnlyDirectChildren() {
        let directory = temporary.url
        let child = directory.appendingPathComponent("x.gguf")
        let sibling = directory.deletingLastPathComponent().appendingPathComponent("x.gguf")
        let nested = directory.appendingPathComponent("sub").appendingPathComponent("x.gguf")
        let bundled = URL(fileURLWithPath: "/Applications/Mimidasu.app/Contents/Resources/models/x.gguf")

        #expect(ModelInventory.isAppOwned(child, modelsDirectory: directory))
        #expect(
            !ModelInventory.isAppOwned(sibling, modelsDirectory: directory),
            "a sibling of the models directory is outside"
        )
        #expect(
            !ModelInventory.isAppOwned(nested, modelsDirectory: directory),
            "a nested subdirectory is outside"
        )
        #expect(
            !ModelInventory.isAppOwned(bundled, modelsDirectory: directory),
            "a bundled copy is outside"
        )
    }

    // MARK: - replacement

    @Test("replacement keeps the first remaining choice in picker order")
    func replacementKeepsFirstRemaining() {
        #expect(ModelInventory.replacement(deleting: .haas, installed: [.lite, .haas, .full]) == .lite)
        #expect(ModelInventory.replacement(deleting: .lite, installed: [.lite, .haas, .full]) == .haas)
        #expect(
            ModelInventory.replacement(deleting: .lite, installed: [.lite]) == nil,
            "the only installed model has no replacement"
        )
        #expect(
            ModelInventory.replacement(deleting: .full, installed: [.haas, .full]) == .haas,
            "a subset still resolves to the first remaining entry"
        )
    }

    // MARK: - canDelete

    @Test("canDelete allows one of two idle installs")
    func canDeleteAllowsTwoIdleInstalls() {
        #expect(ModelInventory.canDelete(.haas, installed: [.lite, .haas], isLiveOrStopping: false))
    }

    @Test("canDelete refuses the only install")
    func canDeleteRefusesTheOnlyInstall() {
        #expect(!ModelInventory.canDelete(.lite, installed: [.lite], isLiveOrStopping: false))
    }

    @Test("canDelete refuses when no model is installed")
    func canDeleteRefusesWithNoInstalls() {
        #expect(!ModelInventory.canDelete(.lite, installed: [], isLiveOrStopping: false))
    }

    @Test("canDelete refuses a choice outside the installed set")
    func canDeleteRefusesAnUninstalledChoice() {
        #expect(!ModelInventory.canDelete(.full, installed: [.lite, .haas], isLiveOrStopping: false))
    }

    @Test("canDelete refuses every live or stopping phase")
    func canDeleteRefusesLiveOrStoppingPhases() {
        let phases: [SessionPhase] = [.starting, .running, .sourceLost, .paused, .stopping]

        for phase in phases {
            #expect(
                !ModelInventory.canDelete(
                    .haas,
                    installed: [.lite, .haas],
                    isLiveOrStopping: SessionPhaseMachine.isLiveOrStopping(phase)
                ),
                "\(phase) must refuse deletion"
            )
        }
    }

    @Test("canDelete allows the non-live phases when another model remains")
    func canDeleteAllowsNonLivePhases() {
        let phases: [SessionPhase] = [.idle, .failed("boom")]

        for phase in phases {
            #expect(
                !SessionPhaseMachine.isLiveOrStopping(phase),
                "\(phase) is not live or stopping"
            )
            #expect(
                ModelInventory.canDelete(
                    .haas,
                    installed: [.lite, .haas],
                    isLiveOrStopping: SessionPhaseMachine.isLiveOrStopping(phase)
                ),
                "\(phase) is not live or stopping, so the delete is allowed"
            )
        }
    }
}
