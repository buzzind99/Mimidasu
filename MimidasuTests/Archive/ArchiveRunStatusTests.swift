import Foundation
@testable import Mimidasu
import Testing

private let englishStatus = ArchiveTranslationJob.RunStatus(
    sessionID: 42, lang: "en", engine: .google
)

struct ArchiveScopedGateCase: Sendable {
    let activity: ArchiveTranslationJob.Activity
    let sessionID: Int64
    let lang: String?
    let expected: Bool
}

private let scopedGateCases: [ArchiveScopedGateCase] = [
    ArchiveScopedGateCase(activity: .idle, sessionID: 42, lang: nil, expected: false),
    ArchiveScopedGateCase(activity: .idle, sessionID: 42, lang: "en", expected: false),
    ArchiveScopedGateCase(activity: .idle, sessionID: 42, lang: "fr", expected: false),
    ArchiveScopedGateCase(activity: .idle, sessionID: 7, lang: nil, expected: false),
    ArchiveScopedGateCase(activity: .idle, sessionID: 7, lang: "en", expected: false),
    ArchiveScopedGateCase(activity: .idle, sessionID: 7, lang: "fr", expected: false),
    ArchiveScopedGateCase(activity: .claimed(englishStatus), sessionID: 42, lang: nil, expected: true),
    ArchiveScopedGateCase(activity: .claimed(englishStatus), sessionID: 42, lang: "en", expected: true),
    ArchiveScopedGateCase(activity: .claimed(englishStatus), sessionID: 42, lang: "fr", expected: false),
    ArchiveScopedGateCase(activity: .claimed(englishStatus), sessionID: 7, lang: nil, expected: false),
    ArchiveScopedGateCase(activity: .claimed(englishStatus), sessionID: 7, lang: "en", expected: false),
    ArchiveScopedGateCase(activity: .claimed(englishStatus), sessionID: 7, lang: "fr", expected: false),
    ArchiveScopedGateCase(activity: .running(englishStatus), sessionID: 42, lang: nil, expected: true),
    ArchiveScopedGateCase(activity: .running(englishStatus), sessionID: 42, lang: "en", expected: true),
    ArchiveScopedGateCase(activity: .running(englishStatus), sessionID: 42, lang: "fr", expected: false),
    ArchiveScopedGateCase(activity: .running(englishStatus), sessionID: 7, lang: nil, expected: false),
    ArchiveScopedGateCase(activity: .running(englishStatus), sessionID: 7, lang: "en", expected: false),
    ArchiveScopedGateCase(activity: .running(englishStatus), sessionID: 7, lang: "fr", expected: false)
]

/// The pure run-status surface: the scoped busy truth table, the global busy
/// flag, the status projection, status equality, and the job's scoped read.
@Suite("Archive translation run status")
struct ArchiveRunStatusTests {

    @Test(
        "the scoped busy gate matches the run's session and, when given, its language",
        arguments: scopedGateCases
    )
    func scopedBusyGate(gateCase: ArchiveScopedGateCase) {
        let busy = gateCase.activity.isBusy(sessionID: gateCase.sessionID, lang: gateCase.lang)

        #expect(busy == gateCase.expected)
    }

    @Test(
        "the global busy flag is true exactly while claimed or running",
        arguments: zip(
            [ArchiveTranslationJob.Activity.idle, .claimed(englishStatus), .running(englishStatus)],
            [false, true, true]
        )
    )
    func globalBusy(activity: ArchiveTranslationJob.Activity, expected: Bool) {
        #expect(activity.isBusy == expected)
    }

    @Test("an idle activity carries no run status")
    func idleHasNoRunStatus() {
        #expect(ArchiveTranslationJob.Activity.idle.runStatus == nil)
    }

    @Test("a claimed activity carries its run status")
    func claimedCarriesItsStatus() {
        #expect(ArchiveTranslationJob.Activity.claimed(englishStatus).runStatus == englishStatus)
    }

    @Test("a running activity carries its run status")
    func runningCarriesItsStatus() {
        #expect(ArchiveTranslationJob.Activity.running(englishStatus).runStatus == englishStatus)
    }

    @Test("statuses carrying the same session, language, and engine are equal")
    func sameStatusIsEqual() {
        let same = ArchiveTranslationJob.RunStatus(sessionID: 42, lang: "en", engine: .google)

        #expect(englishStatus == same)
    }

    @Test("activities carrying equal statuses compare equal")
    func equalStatusActivitiesAreEqual() {
        let same = ArchiveTranslationJob.RunStatus(sessionID: 42, lang: "en", engine: .google)

        #expect(ArchiveTranslationJob.Activity.claimed(englishStatus) == .claimed(same))
        #expect(ArchiveTranslationJob.Activity.running(englishStatus) == .running(same))
    }

    @Test(
        "status equality distinguishes the session, the language, and the engine",
        arguments: [
            ArchiveTranslationJob.RunStatus(sessionID: 43, lang: "en", engine: .google),
            ArchiveTranslationJob.RunStatus(sessionID: 42, lang: "fr", engine: .google),
            ArchiveTranslationJob.RunStatus(sessionID: 42, lang: "en", engine: .deepl)
        ]
    )
    func statusEqualityDistinguishesEachValue(other: ArchiveTranslationJob.RunStatus) {
        #expect(englishStatus != other)
    }

    @Test("the job forwards the global and scoped busy gates")
    @MainActor
    func jobForwardsTheBusyGates() {
        let job = ArchiveTranslationJob()
        #expect(!job.isBusy, "a fresh job is not busy")

        #expect(job.claim(ArchiveTranslationJobFixtures.makeRequest()))

        #expect(job.isBusy)
        #expect(job.isBusy(sessionID: 42))
        #expect(job.isBusy(sessionID: 42, lang: "en"))
        #expect(!job.isBusy(sessionID: 7))
        #expect(!job.isBusy(sessionID: 42, lang: "fr"))
    }

    @Test("the job reports idle for a foreign session and its claim for the run's session")
    @MainActor
    func activityForScopesTheClaimToItsSession() {
        let job = ArchiveTranslationJob()
        let request = ArchiveTranslationJobFixtures.makeRequest()

        #expect(job.activity(for: request.sessionID) == .idle, "a fresh job is idle for every session")
        #expect(job.activity(for: request.sessionID + 1) == .idle)

        #expect(job.claim(request))

        #expect(job.activity(for: request.sessionID) == .claimed(englishStatus))
        #expect(job.activity(for: request.sessionID + 1) == .idle, "a foreign session never sees the claim")
    }
}
