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

    @Test("a request prefills the draft with the session's name")
    func requestPrefillsTheDraft() {
        let state = ArchiveWindowState()

        state.requestRename(summary(name: "Lecture"))

        #expect(state.renameDraft == "Lecture")
        #expect(state.pendingRename?.id == 7)
    }

    @Test("an auto-titled session opens the question with an empty draft")
    func requestPrefillsAnEmptyDraft() {
        let state = ArchiveWindowState()

        state.requestRename(summary(name: nil))

        #expect(state.renameDraft.isEmpty)
    }

    @Test("the stored name is trimmed")
    func theStoredNameIsTrimmed() {
        let state = ArchiveWindowState()

        state.renameDraft = "  Lecture  "

        #expect(state.renameValue == "Lecture")
    }

    @Test("an empty draft clears the name back to the auto-title")
    func anEmptyDraftClearsTheName() {
        let state = ArchiveWindowState()

        state.renameDraft = "   "

        #expect(state.renameValue == nil)
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

    @Test("the badge is the uppercase primary subtag")
    func badgeIsThePrimarySubtag() {
        #expect(LanguageBadge.code(for: "en") == "EN")
        #expect(LanguageBadge.code(for: "zh-Hans") == "ZH")
    }

    @Test("an unknown code keeps its own badge")
    func unknownCodeKeepsItsOwnBadge() {
        #expect(LanguageBadge.code(for: "xx") == "XX")
        #expect(
            TargetLanguage(code: "xx").code == "en",
            "the target-language table falls back to English — the badge must not"
        )
    }

    @Test("an archive chip's badge follows the same rule")
    func chipBadgeFollowsTheSameRule() {
        #expect(ArchiveLanguageCount(lang: "zh-Hans", translated: 0).badgeCode == "ZH")
        #expect(ArchiveLanguageCount(lang: "xx", translated: 0).badgeCode == "XX")
    }
}

/// The language chip's VoiceOver text: the counts, plus the "translating"
/// note while a bulk run claims the language — one string for the chip and
/// the banner's viewed-language label.
@Suite("Archive language chip accessibility")
struct ArchiveLanguageChipAccessibilityTests {

    @Test("the idle chip reads its counts")
    func idleChipReadsItsCounts() {
        #expect(
            ArchiveLanguageCount(lang: "fr", translated: 40)
                .accessibilityText(of: 183, busy: false) == "FR 40/183"
        )
    }

    @Test("a busy chip adds the translating note")
    func busyChipAddsTheTranslatingNote() {
        #expect(
            ArchiveLanguageCount(lang: "fr", translated: 40)
                .accessibilityText(of: 183, busy: true) == "FR 40/183, translating"
        )
    }
}
