import Foundation
@testable import Mimidasu
import SwiftUI
import Testing

/// The rename question both archive surfaces raise — the archive window's
/// rows and the opened archive's banner share one implementation, so the
/// slot's rule (trim, nil when empty) and the draft's prefill are covered
/// once.
@MainActor
@Suite("Archive rename confirmation")
struct ArchiveRenameConfirmationTests {

    private func summary(name: String?) -> ArchivedSessionSummary {
        ArchivedSessionSummary(
            id: 7,
            status: .complete,
            saved: false,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            durationS: 90,
            pausedMS: 0,
            sentenceCount: 3,
            targetLang: "en",
            model: "test-model",
            chunkMS: 160,
            name: name,
            firstSentence: "こんにちは"
        )
    }

    @Test(
        "a request prefills the draft with the session's name, or leaves it empty",
        arguments: [
            (Optional("Lecture"), "Lecture"),
            (nil, ""),
        ]
    )
    func requestPrefillsTheDraft(name: String?, expected: String) {
        let state = ArchiveWindowState()

        state.requestRename(summary(name: name))

        #expect(state.renameDraft == expected)
        #expect(state.pendingRename?.id == 7)
    }

    @Test(
        "the stored name is trimmed, and a blank draft clears it back to the auto-title",
        arguments: [
            ("  Lecture  ", Optional("Lecture")),
            ("   ", nil),
        ]
    )
    func storedNameIsTrimmed(draft: String, expected: String?) {
        let state = ArchiveWindowState()

        state.renameDraft = draft

        #expect(state.renameValue == expected)
    }
}

/// The shared rename question's own decisions: what Save stores, what Cancel
/// leaves alone, and what a dismissal does.
@MainActor
@Suite("Archive rename confirmation actions")
struct ArchiveRenameConfirmationActionTests {

    private func metadata() -> SessionMetadata {
        SessionMetadata(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            sourceLang: "ja",
            targetLang: "en",
            model: "test-model",
            chunkMS: 160
        )
    }

    private func sentence(_ index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: Double(index), endS: Double(index) + 1.5, lang: "ja", text: text)
    }

    /// A stored session, so a rename has something to land on.
    private func makeModel() async throws -> (AppModel, Int64) {
        let store = isolatedArchive()
        let id = try #require(
            store.append(
                sentence: sentence(0, text: "こんにちは"), sessionID: nil, metadata: metadata()
            )
        )
        store.finalize(session: id, durationMS: 90000, saved: false)
        let model = AppModel(
            favorites: isolatedFavorites(), archive: store,
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return (model, id)
    }

    private func summary(id: Int64) -> ArchivedSessionSummary {
        ArchivedSessionSummary(
            id: id,
            status: .complete,
            saved: false,
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            durationS: 90,
            pausedMS: 0,
            sentenceCount: 1,
            targetLang: "en",
            model: "test-model",
            chunkMS: 160,
            name: "Lecture",
            firstSentence: "こんにちは"
        )
    }

    @Test("Save stores the name under the pending session and clears the slot")
    func saveStoresTheName() async throws {
        let (model, id) = try await makeModel()
        var pending: ArchivedSessionSummary? = summary(id: id)
        let confirmation = ArchiveRenameConfirmation(
            model: model,
            pendingRename: Binding(get: { pending }, set: { newValue in pending = newValue }),
            draft: .constant("  Lecture 3  "),
            renamedName: { "Lecture 3" }
        )

        confirmation.save()

        #expect(model.archive.list().first?.name == "Lecture 3")
        #expect(pending == nil)
    }

    @Test("Save reads the name when it runs, not when the question was built")
    func saveReadsTheNameLate() async throws {
        let (model, id) = try await makeModel()
        var pending: ArchivedSessionSummary? = summary(id: id)
        var name = "First"
        let confirmation = ArchiveRenameConfirmation(
            model: model,
            pendingRename: Binding(get: { pending }, set: { newValue in pending = newValue }),
            draft: .constant(""),
            renamedName: { name }
        )
        name = "Second"

        confirmation.save()

        #expect(model.archive.list().first?.name == "Second")
    }

    @Test("Cancel clears the slot and stores nothing")
    func cancelStoresNothing() async throws {
        let (model, id) = try await makeModel()
        var pending: ArchivedSessionSummary? = summary(id: id)
        let confirmation = ArchiveRenameConfirmation(
            model: model,
            pendingRename: Binding(get: { pending }, set: { newValue in pending = newValue }),
            draft: .constant("Renamed"),
            renamedName: { "Renamed" }
        )

        confirmation.cancel()

        #expect(pending == nil)
        #expect(model.archive.list().first?.name == nil)
    }
}

/// The language badge's code: the uppercase primary subtag of a raw code —
/// the archive chips' badge and the target-language picker's row badge.
@Suite("Archive language badge")
struct ArchiveLanguageBadgeTests {

    @Test("an unknown code keeps its own badge, never the target-language fallback")
    func unknownCodeKeepsItsOwnBadge() {
        #expect(LanguageBadge.code(for: "xx") == "XX")
        #expect(ArchiveLanguageCount(lang: "xx", translated: 0).badgeCode == "XX")
    }
}

/// The language chip's VoiceOver text: the counts, plus the "translating"
/// note while a bulk run claims the language — one string for the chip and
/// the banner's viewed-language label.
@Suite("Archive language chip accessibility")
struct ArchiveLanguageChipAccessibilityTests {

    @Test(
        "the chip reads its counts, plus the translating note while a run claims it",
        arguments: [
            (false, "FR 40/183"),
            (true, "FR 40/183, translating")
        ]
    )
    func chipReadsItsCounts(busy: Bool, expected: String) {
        let text = ArchiveLanguageCount(lang: "fr", translated: 40)
            .accessibilityText(of: 183, busy: busy)

        #expect(text == expected)
    }
}
