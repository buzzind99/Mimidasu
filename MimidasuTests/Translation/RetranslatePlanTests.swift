import Foundation
@testable import Mimidasu
import Testing

// MARK: - Fixtures

struct RetranslatePlanFixture: Sendable {
    var surface: RetranslateSurface = .live
    var target: TargetLanguage = .english
    var selection: RetranslateEngine = .session
    var effectiveSelection: RetranslateEngine = .session
    var highFidelityOffered = true
    var highFidelityKnownUnavailable = false
    var activeEngineKind: TranslationEngineKind = .appleFast
    var runsFast = true
    var runsHighFidelity = false
    var attachedProvider: TranslationProvider?
    var workerAttached = true
    var status: TranslationStatus = .ready
    var phaseIsLive = true
    var keyed: Set<TranslationProvider> = []
    var configured: Set<TranslationProvider> = []
    var pendingIndexes: Set<Int> = []
    var archiveJobRunning = false
    var showsMarker = true
    var probeTargetCode: String?

    func context() -> RetranslateContext {
        RetranslateContext(
            surface: surface,
            target: target,
            selection: selection,
            effectiveSelection: effectiveSelection,
            tier: RetranslateTierFacts(
                highFidelityOffered: highFidelityOffered,
                highFidelityKnownUnavailable: highFidelityKnownUnavailable
            ),
            live: RetranslateLiveFacts(
                activeEngineKind: activeEngineKind,
                runsFast: runsFast,
                runsHighFidelity: runsHighFidelity,
                attachedProvider: attachedProvider,
                workerAttached: workerAttached,
                status: status,
                phaseIsLive: phaseIsLive
            ),
            keys: RetranslateKeyFacts(keyed: keyed, configured: configured),
            row: RetranslateRowFacts(
                pendingIndexes: pendingIndexes,
                archiveJobRunning: archiveJobRunning,
                showsMarker: showsMarker,
                probeTargetCode: probeTargetCode
            )
        )
    }

    func plan() -> RetranslatePlan {
        RetranslatePlan(context: context())
    }
}

private func makeEntry(
    index: Int = 0,
    language: String = "en",
    engine: TranslationEngineKind? = nil
) -> SessionEntry {
    var entry = SessionEntry(sentence: makeSentence(index: index))
    entry.replaceTranslation(
        SentenceTranslation(lang: language, text: "translated", engine: engine)
    )
    return entry
}

// MARK: - Route table

struct RetranslateRouteCase: Sendable, CustomTestStringConvertible {
    let name: String
    let surface: RetranslateSurface
    let selection: RetranslateEngine
    let effectiveSelection: RetranslateEngine
    var activeEngineKind: TranslationEngineKind = .appleFast
    var runsFast = true
    var runsHighFidelity = false
    var attachedProvider: TranslationProvider?
    var keyed: Set<TranslationProvider> = []
    var highFidelityKnownUnavailable = false
    let expected: RetranslateRoute

    var testDescription: String {
        name
    }

    var expectedIsAlternate: Bool {
        if case .lane = expected {
            return true
        }
        return false
    }
}

private let retranslateRetranslateRouteCases: [RetranslateRouteCase] = [
    RetranslateRouteCase(
        name: "live session",
        surface: .live,
        selection: .session,
        effectiveSelection: .session,
        expected: .session
    ),
    RetranslateRouteCase(
        name: "live fast on a live fast session",
        surface: .live,
        selection: .appleFast,
        effectiveSelection: .appleFast,
        expected: .session
    ),
    RetranslateRouteCase(
        name: "live fast on a live high-fidelity session",
        surface: .live,
        selection: .appleFast,
        effectiveSelection: .appleFast,
        activeEngineKind: .appleHighFidelity,
        runsFast: false,
        runsHighFidelity: true,
        expected: .lane(.appleFast)
    ),
    RetranslateRouteCase(
        name: "live fast with an unproven live identity",
        surface: .live,
        selection: .appleFast,
        effectiveSelection: .appleFast,
        runsFast: false,
        expected: .lane(.appleFast)
    ),
    RetranslateRouteCase(
        name: "live high fidelity on a live high-fidelity session",
        surface: .live,
        selection: .appleHighFidelity,
        effectiveSelection: .appleHighFidelity,
        activeEngineKind: .appleHighFidelity,
        runsFast: false,
        runsHighFidelity: true,
        expected: .session
    ),
    RetranslateRouteCase(
        name: "live high fidelity on a live fast session",
        surface: .live,
        selection: .appleHighFidelity,
        effectiveSelection: .appleHighFidelity,
        expected: .lane(.appleHighFidelity)
    ),
    RetranslateRouteCase(
        name: "live high fidelity degraded to fast",
        surface: .live,
        selection: .appleHighFidelity,
        effectiveSelection: .appleFast,
        runsFast: false,
        highFidelityKnownUnavailable: true,
        expected: .lane(.appleFast)
    ),
    RetranslateRouteCase(
        name: "live external matching the attached provider",
        surface: .live,
        selection: .google,
        effectiveSelection: .google,
        attachedProvider: .google,
        expected: .session
    ),
    RetranslateRouteCase(
        name: "live external with a stored key",
        surface: .live,
        selection: .deepl,
        effectiveSelection: .deepl,
        keyed: [.deepl],
        expected: .lane(.deepl)
    ),
    RetranslateRouteCase(
        name: "live external without a stored key",
        surface: .live,
        selection: .deepl,
        effectiveSelection: .deepl,
        expected: .unavailable("No API key stored for DeepL.")
    ),
    RetranslateRouteCase(
        name: "archive session",
        surface: .archive,
        selection: .session,
        effectiveSelection: .session,
        expected: .lane(.appleFast)
    ),
    RetranslateRouteCase(
        name: "archive fast",
        surface: .archive,
        selection: .appleFast,
        effectiveSelection: .appleFast,
        expected: .lane(.appleFast)
    ),
    RetranslateRouteCase(
        name: "archive high fidelity",
        surface: .archive,
        selection: .appleHighFidelity,
        effectiveSelection: .appleHighFidelity,
        expected: .lane(.appleHighFidelity)
    ),
    RetranslateRouteCase(
        name: "archive high fidelity degraded to fast",
        surface: .archive,
        selection: .appleHighFidelity,
        effectiveSelection: .appleFast,
        highFidelityKnownUnavailable: true,
        expected: .lane(.appleFast)
    ),
    RetranslateRouteCase(
        name: "archive external with a stored key",
        surface: .archive,
        selection: .google,
        effectiveSelection: .google,
        keyed: [.google],
        expected: .lane(.google)
    ),
    RetranslateRouteCase(
        name: "archive external without a stored key",
        surface: .archive,
        selection: .deepl,
        effectiveSelection: .deepl,
        expected: .unavailable("No API key stored for DeepL.")
    )
]

// MARK: - Options table

struct RetranslateOptionsCase: Sendable, CustomTestStringConvertible {
    let name: String
    var runsFast = false
    var runsHighFidelity = false
    var highFidelityOffered = true
    var configured: Set<TranslationProvider> = []
    var attachedProvider: TranslationProvider?
    let expected: [RetranslateEngine]

    var testDescription: String {
        name
    }
}

private let liveOptionsCases: [RetranslateOptionsCase] = [
    RetranslateOptionsCase(
        name: "all Apple tiers when the live engine proves neither",
        expected: [.session, .appleFast, .appleHighFidelity]
    ),
    RetranslateOptionsCase(
        name: "fast hidden when the live session runs fast",
        runsFast: true,
        expected: [.session, .appleHighFidelity]
    ),
    RetranslateOptionsCase(
        name: "high fidelity hidden when the live session runs it",
        runsHighFidelity: true,
        expected: [.session, .appleFast]
    ),
    RetranslateOptionsCase(
        name: "high fidelity hidden when the OS cannot offer it",
        highFidelityOffered: false,
        expected: [.session, .appleFast]
    ),
    RetranslateOptionsCase(
        name: "configured externals in catalog order without the attached provider",
        configured: [.deepl, .google, .openai],
        attachedProvider: .deepl,
        expected: [.session, .appleFast, .appleHighFidelity, .google, .openai]
    )
]

struct RetranslateGateCase: Sendable, CustomTestStringConvertible {
    let name: String
    let workerAttached: Bool
    let status: TranslationStatus
    let expected: Bool

    var testDescription: String {
        name
    }
}

private let sessionGateCases: [RetranslateGateCase] = [
    RetranslateGateCase(
        name: "no worker",
        workerAttached: false,
        status: .ready,
        expected: false
    ),
    RetranslateGateCase(
        name: "unavailable status",
        workerAttached: true,
        status: .unavailable("boom", .permanent),
        expected: false
    ),
    RetranslateGateCase(
        name: "attached worker and ready status",
        workerAttached: true,
        status: .ready,
        expected: true
    )
]

// MARK: - Marker table

struct RetranslateProvenanceCase: Sendable, CustomTestStringConvertible {
    let name: String
    var surface: RetranslateSurface = .live
    var translationLanguage = "en"
    var stamp: TranslationEngineKind? = .google
    var showsMarker = true
    var highFidelityKnownUnavailable = false
    var probeTargetCode: String? = "en"
    var activeEngineKind: TranslationEngineKind = .appleFast
    let expected: String?

    var testDescription: String {
        name
    }
}

private let markerCases: [RetranslateProvenanceCase] = [
    RetranslateProvenanceCase(
        name: "marker toggle off",
        showsMarker: false,
        expected: nil
    ),
    RetranslateProvenanceCase(
        name: "no translation for the target language",
        translationLanguage: "de",
        expected: nil
    ),
    RetranslateProvenanceCase(
        name: "session-engine stamp",
        stamp: nil,
        expected: nil
    ),
    RetranslateProvenanceCase(
        name: "high fidelity known unavailable",
        stamp: .appleHighFidelity,
        highFidelityKnownUnavailable: true,
        expected: nil
    ),
    RetranslateProvenanceCase(
        name: "archive stamp regardless of the live engine",
        surface: .archive,
        stamp: .google,
        activeEngineKind: .google,
        expected: "· via Google Translate"
    ),
    RetranslateProvenanceCase(
        name: "live Apple stamp while the probe has not landed",
        stamp: .appleFast,
        probeTargetCode: nil,
        activeEngineKind: .google,
        expected: nil
    ),
    RetranslateProvenanceCase(
        name: "live stamp equal to the active engine",
        stamp: .google,
        activeEngineKind: .google,
        expected: nil
    ),
    RetranslateProvenanceCase(
        name: "live stamp different from the active engine",
        stamp: .appleHighFidelity,
        activeEngineKind: .appleFast,
        expected: "· via Apple Intelligence"
    )
]

// MARK: - Suite

@MainActor
@Suite("RetranslatePlanTests")
struct RetranslatePlanTests {

    @Test("routes a retry from the tier-degraded selection", arguments: retranslateRetranslateRouteCases)
    func route(_ testCase: RetranslateRouteCase) {
        let plan = plan(for: testCase)

        #expect(plan.route == testCase.expected)
    }

    @Test("marks a route alternate exactly when it runs a dedicated engine", arguments: retranslateRetranslateRouteCases)
    func alternate(_ testCase: RetranslateRouteCase) {
        let plan = plan(for: testCase)

        #expect(plan.isAlternate == testCase.expectedIsAlternate)
    }

    @Test("live options follow the live engine and configured providers", arguments: liveOptionsCases)
    func liveOptions(_ testCase: RetranslateOptionsCase) {
        var fixture = RetranslatePlanFixture()
        fixture.runsFast = testCase.runsFast
        fixture.runsHighFidelity = testCase.runsHighFidelity
        fixture.highFidelityOffered = testCase.highFidelityOffered
        fixture.configured = testCase.configured
        fixture.attachedProvider = testCase.attachedProvider
        let plan = fixture.plan()

        #expect(plan.options.map(\.engine) == testCase.expected)
        #expect(plan.options.map(\.id) == testCase.expected.map(\.rawValue))
        #expect(plan.options.allSatisfy { option in option.isSelectable && option.isConfigured })
    }

    @Test("archive options list high fidelity, fast, then every external with its configured flag")
    func archiveOptions() {
        var fixture = RetranslatePlanFixture()
        fixture.surface = .archive
        fixture.configured = [.google, .deepl]
        let plan = fixture.plan()

        #expect(
            plan.options.map(\.engine) == [
                .appleHighFidelity, .appleFast, .google, .deepl, .openrouter,
                .openai, .anthropic, .moonshot, .zai, .deepseek, .xai
            ]
        )
        #expect(
            plan.options.map(\.isSelectable) == [
                true, true, true, true, false, false, false, false, false, false, false
            ]
        )
        #expect(
            plan.options.map(\.isConfigured) == [
                true, true, true, true, false, false, false, false, false, false, false
            ]
        )
    }

    @Test("archive options omit high fidelity when it is not offered")
    func archiveOptionsWithoutHighFidelity() {
        var fixture = RetranslatePlanFixture()
        fixture.surface = .archive
        fixture.highFidelityOffered = false
        let plan = fixture.plan()

        #expect(
            plan.options.map(\.engine) == [
                .appleFast, .google, .deepl, .openrouter, .openai,
                .anthropic, .moonshot, .zai, .deepseek, .xai
            ]
        )
    }

    @Test("displayed engine prefers the persisted selection")
    func displayedEnginePrefersSelection() {
        var fixture = RetranslatePlanFixture()
        fixture.runsFast = false
        fixture.selection = .appleFast
        fixture.effectiveSelection = .appleFast

        #expect(fixture.plan().displayedEngine == .appleFast)
    }

    @Test("displayed engine falls back to the effective selection")
    func displayedEngineFallsBackToEffective() {
        var fixture = RetranslatePlanFixture()
        fixture.runsFast = false
        fixture.selection = .appleHighFidelity
        fixture.effectiveSelection = .appleFast
        fixture.highFidelityOffered = false

        #expect(fixture.plan().displayedEngine == .appleFast)
    }

    @Test("displayed engine falls back to the session engine")
    func displayedEngineFallsBackToSession() {
        var fixture = RetranslatePlanFixture()
        fixture.runsFast = false
        fixture.selection = .deepl
        fixture.effectiveSelection = .deepl

        #expect(fixture.plan().displayedEngine == .session)
    }

    @Test("archive displayed engine keeps a listed selection and otherwise uses the default")
    func archiveDisplayedEngine() {
        var selected = RetranslatePlanFixture()
        selected.surface = .archive
        selected.selection = .deepl
        selected.effectiveSelection = .deepl

        #expect(selected.plan().displayedEngine == .deepl)

        var unlisted = RetranslatePlanFixture()
        unlisted.surface = .archive
        unlisted.selection = .session
        unlisted.effectiveSelection = .session

        #expect(unlisted.plan().displayedEngine == .appleHighFidelity)
    }

    @Test("live defaults to the session engine")
    func liveDefaultEngine() {
        #expect(RetranslatePlanFixture().plan().defaultEngine == .session)
    }

    @Test("archive defaults to high fidelity when it is offered")
    func archiveDefaultEngineOffered() {
        var fixture = RetranslatePlanFixture()
        fixture.surface = .archive

        #expect(fixture.plan().defaultEngine == .appleHighFidelity)
    }

    @Test("archive defaults to fast when high fidelity is not offered")
    func archiveDefaultEngineNotOffered() {
        var fixture = RetranslatePlanFixture()
        fixture.surface = .archive
        fixture.highFidelityOffered = false

        #expect(fixture.plan().defaultEngine == .appleFast)
    }

    @Test("a row is disabled while the live phase is not live")
    func gateLivePhaseNotLive() {
        var fixture = RetranslatePlanFixture()
        fixture.phaseIsLive = false
        let row = fixture.plan().row(for: makeEntry())

        #expect(!row.isEnabled)
    }

    @Test("a pending row is disabled and reports that it is retranslating")
    func gatePendingRow() {
        var fixture = RetranslatePlanFixture()
        fixture.pendingIndexes = [0]
        let row = fixture.plan().row(for: makeEntry(index: 0))

        #expect(!row.isEnabled)
        #expect(row.isRetranslating)
    }

    @Test("a live lane row is enabled without a queue worker")
    func gateLiveLaneWithoutWorker() {
        var fixture = RetranslatePlanFixture()
        fixture.selection = .deepl
        fixture.effectiveSelection = .deepl
        fixture.keyed = [.deepl]
        fixture.workerAttached = false
        fixture.status = .unavailable("boom", .permanent)
        let plan = fixture.plan()

        #expect(plan.route == .lane(.deepl))
        #expect(plan.row(for: makeEntry()).isEnabled)
    }

    @Test("a live session row needs a worker and a non-unavailable status", arguments: sessionGateCases)
    func gateLiveSession(_ testCase: RetranslateGateCase) {
        var fixture = RetranslatePlanFixture()
        fixture.workerAttached = testCase.workerAttached
        fixture.status = testCase.status
        let row = fixture.plan().row(for: makeEntry())

        #expect(row.isEnabled == testCase.expected)
    }

    @Test("a live unavailable route disables the row")
    func gateLiveUnavailable() {
        var fixture = RetranslatePlanFixture()
        fixture.selection = .deepl
        fixture.effectiveSelection = .deepl
        let plan = fixture.plan()

        #expect(plan.route == .unavailable("No API key stored for DeepL."))
        #expect(!plan.row(for: makeEntry()).isEnabled)
    }

    @Test("an archive row is disabled while its sentence is pending")
    func gateArchivePending() {
        var fixture = RetranslatePlanFixture()
        fixture.surface = .archive
        fixture.pendingIndexes = [0]

        #expect(!fixture.plan().row(for: makeEntry(index: 0)).isEnabled)
    }

    @Test("an archive row is disabled while the bulk job runs")
    func gateArchiveJobRunning() {
        var fixture = RetranslatePlanFixture()
        fixture.surface = .archive
        fixture.archiveJobRunning = true

        #expect(!fixture.plan().row(for: makeEntry()).isEnabled)
    }

    @Test("an archive lane row is enabled")
    func gateArchiveLane() {
        var fixture = RetranslatePlanFixture()
        fixture.surface = .archive
        let plan = fixture.plan()

        #expect(plan.route == .lane(.appleFast))
        #expect(plan.row(for: makeEntry()).isEnabled)
    }

    @Test("an archive unavailable route disables the row")
    func gateArchiveUnavailable() {
        var fixture = RetranslatePlanFixture()
        fixture.surface = .archive
        fixture.selection = .deepl
        fixture.effectiveSelection = .deepl
        let plan = fixture.plan()

        #expect(plan.route == .unavailable("No API key stored for DeepL."))
        #expect(!plan.row(for: makeEntry()).isEnabled)
    }

    @Test("markers follow the suppression rules", arguments: markerCases)
    func marker(_ testCase: RetranslateProvenanceCase) {
        var fixture = RetranslatePlanFixture()
        fixture.surface = testCase.surface
        fixture.showsMarker = testCase.showsMarker
        fixture.highFidelityKnownUnavailable = testCase.highFidelityKnownUnavailable
        fixture.probeTargetCode = testCase.probeTargetCode
        fixture.activeEngineKind = testCase.activeEngineKind
        let plan = fixture.plan()
        let entry = makeEntry(
            language: testCase.translationLanguage,
            engine: testCase.stamp
        )

        #expect(plan.row(for: entry).marker == testCase.expected)
    }

    @Test("an unavailable route never enables the row", arguments: [RetranslateSurface.live, .archive])
    func unavailableRouteNeverEnablesRow(surface: RetranslateSurface) {
        var fixture = RetranslatePlanFixture()
        fixture.surface = surface
        fixture.selection = .deepl
        fixture.effectiveSelection = .deepl
        let plan = fixture.plan()

        #expect(plan.route == .unavailable("No API key stored for DeepL."))
        #expect(!plan.row(for: makeEntry()).isEnabled)
    }

    private func plan(for testCase: RetranslateRouteCase) -> RetranslatePlan {
        var fixture = RetranslatePlanFixture()
        fixture.surface = testCase.surface
        fixture.selection = testCase.selection
        fixture.effectiveSelection = testCase.effectiveSelection
        fixture.activeEngineKind = testCase.activeEngineKind
        fixture.runsFast = testCase.runsFast
        fixture.runsHighFidelity = testCase.runsHighFidelity
        fixture.attachedProvider = testCase.attachedProvider
        fixture.keyed = testCase.keyed
        fixture.highFidelityKnownUnavailable = testCase.highFidelityKnownUnavailable
        return fixture.plan()
    }
}
