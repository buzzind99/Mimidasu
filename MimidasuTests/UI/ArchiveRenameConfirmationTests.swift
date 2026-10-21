import Foundation
@testable import Mimidasu
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

    @Test("cancelling clears the slot")
    func cancellingClearsTheSlot() {
        let state = ArchiveWindowState()
        state.requestRename(summary(name: "Lecture"))

        state.pendingRename = nil

        #expect(state.pendingRename == nil)
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
