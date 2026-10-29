import Foundation
@testable import Mimidasu
import Testing

/// The production `AppModel.phase` write sites, encoded as a spec table.
///
/// Each row names the production file and line the write was verified at, the
/// value production writes, the guard immediately before it, and the phase
/// outcome the machine must reproduce. The rows are the contract: if the
/// machine and this table disagree, the table is what production does.
///
/// Rows whose production guard admits more than one phase are listed once per
/// admitted phase — the write site number stays the same.
///
/// The `line` field is documentation: the source check in
/// `ProductionWriteSiteSpecTests` is what keeps the table honest, because it
/// resolves the production sources and compares the call sites it finds with
/// the rows below. A line number alone would rot silently.
enum ProductionSiteTable {

    struct Site: Sendable {
        let number: Int
        let file: String
        let line: Int
        let value: String
        let guardDescription: String
        let from: SessionPhase
        let action: SessionAction
        let to: SessionPhase
        let category: SessionTransition.Category
    }

    static let sites: [Site] = [
        // 1
        Site(
            number: 1, file: "Mimidasu/State/AppModel+Session.swift", line: 344, value: ".needsModel",
            guardDescription: "the machine's `.idle` + unresolved pair (was: `if url == nil, phase == .idle`)",
            from: .idle,
            action: .modelResolved(resolved: false),
            to: .needsModel,
            category: .legal
        ),
        // 2
        Site(
            number: 2, file: "Mimidasu/State/AppModel+Session.swift", line: 344, value: ".idle",
            guardDescription: "the machine's `.needsModel` + resolved pair (was: `else if url != nil, phase == .needsModel`)",
            from: .needsModel,
            action: .modelResolved(resolved: true),
            to: .idle,
            category: .legal
        ),
        // 3
        Site(
            number: 3, file: "Mimidasu/State/AppModel.swift", line: 448, value: ".sourceLost",
            guardDescription: "the machine's `.running`/`.starting` legal-from set (after the .paused deferral)",
            from: .running,
            action: .captureLost("stream died"),
            to: .sourceLost,
            category: .legal
        ),
        // 3 — the second legal from-phase of the same write
        Site(
            number: 3, file: "Mimidasu/State/AppModel.swift", line: 448, value: ".sourceLost",
            guardDescription: "the machine's `.running`/`.starting` legal-from set (after the .paused deferral)",
            from: .starting,
            action: .captureLost("stream died"),
            to: .sourceLost,
            category: .legal
        ),
        // 4
        Site(
            number: 4, file: "Mimidasu/State/AppModel.swift", line: 503, value: ".starting",
            guardDescription: "the machine's `.sourceLost`/`.paused` legal-from set (was an unconditional write)",
            from: .sourceLost,
            action: .captureRestartRequested,
            to: .starting,
            category: .legal
        ),
        // 4 — the resume-deferred caller of the same write
        Site(
            number: 4, file: "Mimidasu/State/AppModel.swift", line: 503, value: ".starting",
            guardDescription: "the machine's `.sourceLost`/`.paused` legal-from set (was an unconditional write)",
            from: .paused,
            action: .captureRestartRequested,
            to: .starting,
            category: .legal
        ),
        // 5
        Site(
            number: 5, file: "Mimidasu/State/AppModel.swift", line: 510, value: ".running",
            guardDescription: "the machine's `.starting` legal-from set (was: `guard phase == .starting`)",
            from: .starting,
            action: .captureRestartSucceeded,
            to: .running,
            category: .legal
        ),
        // 6
        Site(
            number: 6, file: "Mimidasu/State/AppModel.swift", line: 519, value: ".sourceLost",
            guardDescription: "the machine's `.starting` legal-from set (was: `guard phase == .starting`)",
            from: .starting,
            action: .captureRestartFailed("boom"),
            to: .sourceLost,
            category: .legal
        ),
        // 7
        Site(
            number: 7, file: "Mimidasu/State/AppModel+Session.swift", line: 124, value: ".paused",
            guardDescription: "the machine's `.running` legal-from set (was: `guard phase == .running`)",
            from: .running,
            action: .pauseRequested,
            to: .paused,
            category: .legal
        ),
        // 8
        Site(
            number: 8, file: "Mimidasu/State/AppModel+Session.swift", line: 169, value: ".running",
            guardDescription: "the machine's `.paused` legal-from set (was: `guard phase == .paused`)",
            from: .paused,
            action: .resumeSucceeded,
            to: .running,
            category: .legal
        ),
        // 9
        Site(
            number: 9, file: "Mimidasu/State/AppModel+Session.swift", line: 175, value: ".sourceLost",
            guardDescription: "the machine's `.paused` legal-from set (was: `guard phase == .paused`)",
            from: .paused,
            action: .resumeFailed("boom"),
            to: .sourceLost,
            category: .legal
        ),
        // 10
        Site(
            number: 10, file: "Mimidasu/State/AppModel+Session.swift", line: 28, value: ".starting",
            guardDescription: "the machine's `.idle`/`.failed` legal-from set + the terminating latch"
                + " + openArchive == nil + !isCheckingModel",
            from: .idle,
            action: .startRequested,
            to: .starting,
            category: .legal
        ),
        // 10 — the `.failed` arm of the same switch
        Site(
            number: 10, file: "Mimidasu/State/AppModel+Session.swift", line: 28, value: ".starting",
            guardDescription: "the machine's `.idle`/`.failed` legal-from set + the terminating latch"
                + " + openArchive == nil + !isCheckingModel",
            from: .failed("boom"),
            action: .startRequested,
            to: .starting,
            category: .legal
        ),
        // 11
        Site(
            number: 11, file: "Mimidasu/State/AppModel+Session.swift", line: 46, value: ".failed(error.localizedDescription)",
            guardDescription: "the machine's `.starting` legal-from set (was: `guard self.phase == .starting`)",
            from: .starting,
            action: .beginFailed("boom"),
            to: .failed("boom"),
            category: .legal
        ),
        // 12 — the teardown the interrupted bring-up owes
        Site(
            number: 12, file: "Mimidasu/State/AppModel+Session.swift", line: 72, value: "(none — the phase stays)",
            guardDescription: "the machine's compensating branch (was: `guard phase == .starting else"
                + " { await sessionController.stop(); ... }`)",
            from: .stopping,
            action: .beginInterruptedByTeardown,
            to: .stopping,
            category: .compensating
        ),
        // 12 — the wind-back, after the teardown has landed
        Site(
            number: 12, file: "Mimidasu/State/AppModel+Session.swift", line: 79, value: ".idle",
            guardDescription: "the machine's wind-back (was: `if phase == .stopping { phase = .idle }`"
                + " after the teardown)",
            from: .stopping,
            action: .teardownCompleted,
            to: .idle,
            category: .legal
        ),
        // 13
        Site(
            number: 13, file: "Mimidasu/State/AppModel+Session.swift", line: 83, value: ".needsModel",
            guardDescription: "guard started (begin() returned false), after the interruption check",
            from: .starting,
            action: .beginReturnedNoModel,
            to: .needsModel,
            category: .legal
        ),
        // 14
        Site(
            number: 14, file: "Mimidasu/State/AppModel+Session.swift", line: 87, value: ".running",
            guardDescription: "the machine's `.starting` legal-from set",
            from: .starting,
            action: .beginSucceeded,
            to: .running,
            category: .legal
        ),
        // 15 — the `.running` arm
        Site(
            number: 15, file: "Mimidasu/State/AppModel+Session.swift", line: 239, value: ".stopping",
            guardDescription: "the machine's `.starting`/`.running`/`.paused`/`.sourceLost` legal-from set",
            from: .running,
            action: .stopRequested,
            to: .stopping,
            category: .legal
        ),
        // 15 — the `.paused` arm
        Site(
            number: 15, file: "Mimidasu/State/AppModel+Session.swift", line: 239, value: ".stopping",
            guardDescription: "the machine's `.starting`/`.running`/`.paused`/`.sourceLost` legal-from set",
            from: .paused,
            action: .stopRequested,
            to: .stopping,
            category: .legal
        ),
        // 15 — the `.sourceLost` arm
        Site(
            number: 15, file: "Mimidasu/State/AppModel+Session.swift", line: 239, value: ".stopping",
            guardDescription: "the machine's `.starting`/`.running`/`.paused`/`.sourceLost` legal-from set",
            from: .sourceLost,
            action: .stopRequested,
            to: .stopping,
            category: .legal
        ),
        // 15 — the `.starting` arm: a session the user cancels mid-start is
        // stoppable, and a stop during the bring-up must never let the
        // session come up afterwards.
        Site(
            number: 15, file: "Mimidasu/State/AppModel+Session.swift", line: 239, value: ".stopping",
            guardDescription: "the machine's `.starting`/`.running`/`.paused`/`.sourceLost` legal-from set",
            from: .starting,
            action: .stopRequested,
            to: .stopping,
            category: .legal
        ),
        // 16
        Site(
            number: 16, file: "Mimidasu/State/AppModel+SessionLifecycle.swift", line: 21, value: ".idle",
            guardDescription: "the machine's `.stopping`/`.idle` legal-from set (was unconditional, post-teardown)",
            from: .stopping,
            action: .stopCompleted,
            to: .idle,
            category: .legal
        ),
        // 16 — the site-12 race: the phase was already wound back to idle
        Site(
            number: 16, file: "Mimidasu/State/AppModel+SessionLifecycle.swift", line: 21, value: ".idle",
            guardDescription: "the machine's `.stopping`/`.idle` legal-from set; reachable from .idle when site 12 won",
            from: .idle,
            action: .stopCompleted,
            to: .idle,
            category: .legal
        ),
        // 17 — the `.running` arm
        Site(
            number: 17, file: "Mimidasu/State/AppModel+Session.swift", line: 290, value: ".stopping",
            guardDescription: "the machine's live-phase branch (was: `else if phase == .starting || .running"
                + " || .paused || .stopping || .sourceLost`)",
            from: .running,
            action: .terminationStarted,
            to: .stopping,
            category: .legal
        ),
        // 17 — the `.sourceLost` arm
        Site(
            number: 17, file: "Mimidasu/State/AppModel+Session.swift", line: 290, value: ".stopping",
            guardDescription: "the machine's live-phase branch (was: `else if phase == .starting || .running"
                + " || .paused || .stopping || .sourceLost`)",
            from: .sourceLost,
            action: .terminationStarted,
            to: .stopping,
            category: .legal
        ),
        // 17 — the `.starting` arm: quitting during the TCC-prompted bring-up
        Site(
            number: 17, file: "Mimidasu/State/AppModel+Session.swift", line: 290, value: ".stopping",
            guardDescription: "the machine's live-phase branch (was: `else if phase == .starting || .running"
                + " || .paused || .stopping || .sourceLost`)",
            from: .starting,
            action: .terminationStarted,
            to: .stopping,
            category: .legal
        ),
        // 17 — the `.paused` arm: quitting while the session is paused
        Site(
            number: 17, file: "Mimidasu/State/AppModel+Session.swift", line: 290, value: ".stopping",
            guardDescription: "the machine's live-phase branch (was: `else if phase == .starting || .running"
                + " || .paused || .stopping || .sourceLost`)",
            from: .paused,
            action: .terminationStarted,
            to: .stopping,
            category: .legal
        ),
        // 17 — the `.stopping` arm: a stop is already staged and owns the
        // teardown, so the machine waits for it before retiring the engine.
        Site(
            number: 17, file: "Mimidasu/State/AppModel+Session.swift", line: 290, value: "(none — the staged stop owns the teardown)",
            guardDescription: "the machine's staged-stop branch (was: `await stopTask.value`)",
            from: .stopping,
            action: .terminationStarted,
            to: .stopping,
            category: .legal
        ),
        // 18 — the resume request: the machine arms the resume latch, and
        // the phase stays `.paused` until the IOProc is actually back.
        Site(
            number: 18, file: "Mimidasu/State/AppModel+Session.swift", line: 143, value: "(none — the phase stays `.paused`)",
            guardDescription: "the machine's `.paused` legal-from set + the resume latch",
            from: .paused,
            action: .resumeRequested,
            to: .paused,
            category: .legal
        ),
        // 19 — the latch release when a stop won the resume race
        Site(
            number: 19, file: "Mimidasu/State/AppModel+Session.swift", line: 155, value: "(none — the phase stays)",
            guardDescription: "the machine's latch release (the stop won the race)",
            from: .stopping,
            action: .resumeAbandoned,
            to: .stopping,
            category: .legal
        ),
        // 19 — the latch release after the deferred capture rebuild took over
        Site(
            number: 19, file: "Mimidasu/State/AppModel+Session.swift", line: 162, value: "(none — the phase stays)",
            guardDescription: "the machine's latch release (the rebuild moved the phase to `.starting`)",
            from: .starting,
            action: .resumeAbandoned,
            to: .starting,
            category: .legal
        )
    ]
}

extension SessionAction {
    /// The case name, as it appears in a `reducePhase(.…)` call. The
    /// associated values are not part of the name.
    var callLabel: String {
        switch self {
        case .startRequested: "startRequested"
        case .beginSucceeded: "beginSucceeded"
        case .beginReturnedNoModel: "beginReturnedNoModel"
        case .beginFailed: "beginFailed"
        case .beginInterruptedByTeardown: "beginInterruptedByTeardown"
        case .teardownCompleted: "teardownCompleted"
        case .pauseRequested: "pauseRequested"
        case .resumeRequested: "resumeRequested"
        case .resumeSucceeded: "resumeSucceeded"
        case .resumeFailed: "resumeFailed"
        case .resumeAbandoned: "resumeAbandoned"
        case .captureLost: "captureLost"
        case .captureRestartRequested: "captureRestartRequested"
        case .captureRestartSucceeded: "captureRestartSucceeded"
        case .captureRestartFailed: "captureRestartFailed"
        case .modelResolved: "modelResolved"
        case .stopRequested: "stopRequested"
        case .stopCompleted: "stopCompleted"
        case .terminationStarted: "terminationStarted"
        }
    }
}

/// The machine honours the production-site spec table.
struct ProductionWriteSiteSpecTests {

    /// The repository root, from this file's compile-time path: the test
    /// bundle runs from the build directory, so the source has to be found
    /// from the path the compiler recorded.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The production files that write the phase.
    private static let productionFiles = [
        "Mimidasu/State/AppModel.swift",
        "Mimidasu/State/AppModel+Session.swift",
        "Mimidasu/State/AppModel+SessionLifecycle.swift"
    ]

    /// Every one of the production sites appears in the spec table.
    @Test("the spec table covers every production write site")
    func specCoversAllProductionSites() {
        let covered = Set(ProductionSiteTable.sites.map { site in site.number })
        #expect(covered == Set(1 ... 19), "sites covered: \(covered.sorted())")
    }

    /// The spec table names **every** production call site, at the line the
    /// table says, and the production sources name nothing the table forgot.
    ///
    /// This is the check that keeps the table honest. It resolves the
    /// production sources, finds every `reducePhase(.…)` call, and compares
    /// the call sites — the action *and* the line — with the table's rows,
    /// so a new write site, a removed one, or a moved one cannot slip past.
    @Test("the spec table names every production reducePhase call site")
    func specTableMatchesTheProductionCallSites() throws {
        // The call sites production makes: "file#action" → the lines.
        var found: [String: Set<Int>] = [:]
        for file in Self.productionFiles {
            let url = Self.repositoryRoot.appendingPathComponent(file)
            let source = try String(contentsOf: url, encoding: .utf8)
            for match in source.matches(of: /reducePhase\(\.(\w+)/) {
                let line = source[..<match.range.lowerBound]
                    .split(separator: "\n", omittingEmptySubsequences: false).count
                found["\(file)#\(match.1)", default: []].insert(line)
            }
        }

        // The call sites the table names: the same shape.
        var expected: [String: Set<Int>] = [:]
        for site in ProductionSiteTable.sites {
            expected["\(site.file)#\(site.action.callLabel)", default: []].insert(site.line)
        }

        for key in Set(found.keys).union(expected.keys).sorted() {
            #expect(
                found[key] == expected[key],
                """
                the production call site and the spec table disagree at \(key).
                production: \(found[key]?.sorted() ?? [])
                the table: \(expected[key]?.sorted() ?? [])
                """
            )
        }
    }

    /// The machine reproduces today's phase outcome and category for every
    /// production site.
    @Test("the machine reproduces today's outcome for every production site")
    func machineReproducesProductionOutcome() {
        for site in ProductionSiteTable.sites {
            var machine = SessionPhaseMachine(phase: site.from)
            let transition = machine.reduce(site.action)

            #expect(
                machine.phase == site.to,
                "site \(site.number) (\(site.file)#\(site.action.callLabel)) must land on \(site.to), landed on \(machine.phase)"
            )
            #expect(
                transition.phase == site.to,
                "site \(site.number) (\(site.file)#\(site.action.callLabel)) must report \(site.to), reported \(transition.phase)"
            )
            #expect(
                transition.category == site.category,
                "site \(site.number) (\(site.file)#\(site.action.callLabel)) must be \(site.category), was \(transition.category)"
            )
        }
    }

    // MARK: - Termination

    @Test("terminationStarted has no refused from-phase: every phase either stops or retires")
    func terminationHasNoRefusal() {
        for from in SessionPhaseFixtures.all {
            var machine = SessionPhaseMachine(phase: from)
            let transition = machine.reduce(.terminationStarted)

            #expect(machine.isTerminating, "\(from)")
            #expect(transition.isLegal, "\(from)")
            if from == .starting || from == .running || from == .paused || from == .sourceLost {
                #expect(machine.phase == .stopping, "\(from)")
            } else {
                #expect(machine.phase == from, "\(from) must not move")
            }
        }
    }
}
