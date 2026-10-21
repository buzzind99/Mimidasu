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
        let effects: [SessionEffect]
    }

    /// The effect bundle a finished stop runs.
    static let stopCompletionBundle: [SessionEffect] = [
        .drainTranslation,
        .clearToastsAndNotices,
        .finalizeLiveSession,
        .postArchivedRecentToast
    ]

    /// The effect bundle a quit-time teardown runs from a live phase.
    static let terminationTeardownBundle: [SessionEffect] = [
        .stopCapture,
        .drainTranslation,
        .clearToastsAndNotices,
        .finalizeLiveSession,
        .postArchivedRecentToast,
        .retireWarmEngine,
        .postTerminationTeardownComplete
    ]

    static let sites: [Site] = [
        // 1
        Site(
            number: 1,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 387,
            value: ".needsModel",
            guardDescription: "the machine's `.idle` + unresolved pair (was: `if url == nil, phase == .idle`)",
            from: .idle,
            action: .modelResolved(resolved: false),
            to: .needsModel,
            effects: [.warmUpEngine]
        ),
        // 2
        Site(
            number: 2,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 387,
            value: ".idle",
            guardDescription: "the machine's `.needsModel` + resolved pair (was: `else if url != nil, phase == .needsModel`)",
            from: .needsModel,
            action: .modelResolved(resolved: true),
            to: .idle,
            effects: [.warmUpEngine]
        ),
        // 3
        Site(
            number: 3,
            file: "Mimidasu/State/AppModel.swift",
            line: 470,
            value: ".sourceLost",
            guardDescription: "the machine's `.running`/`.starting` legal-from set (after the .paused deferral)",
            from: .running,
            action: .captureLost("stream died"),
            to: .sourceLost,
            effects: [.postCaptureLost("stream died")]
        ),
        // 3 — the second legal from-phase of the same write
        Site(
            number: 3,
            file: "Mimidasu/State/AppModel.swift",
            line: 470,
            value: ".sourceLost",
            guardDescription: "the machine's `.running`/`.starting` legal-from set (after the .paused deferral)",
            from: .starting,
            action: .captureLost("stream died"),
            to: .sourceLost,
            effects: [.postCaptureLost("stream died")]
        ),
        // 4
        Site(
            number: 4,
            file: "Mimidasu/State/AppModel.swift",
            line: 525,
            value: ".starting",
            guardDescription: "the machine's `.sourceLost`/`.paused` legal-from set (was an unconditional write)",
            from: .sourceLost,
            action: .captureRestartRequested,
            to: .starting,
            effects: [.restartCapture]
        ),
        // 4 — the resume-deferred caller of the same write
        Site(
            number: 4,
            file: "Mimidasu/State/AppModel.swift",
            line: 525,
            value: ".starting",
            guardDescription: "the machine's `.sourceLost`/`.paused` legal-from set (was an unconditional write)",
            from: .paused,
            action: .captureRestartRequested,
            to: .starting,
            effects: [.restartCapture]
        ),
        // 5
        Site(
            number: 5,
            file: "Mimidasu/State/AppModel.swift",
            line: 532,
            value: ".running",
            guardDescription: "the machine's `.starting` legal-from set (was: `guard phase == .starting`)",
            from: .starting,
            action: .captureRestartSucceeded,
            to: .running,
            effects: [.armNoAudioWatchdog]
        ),
        // 6
        Site(
            number: 6,
            file: "Mimidasu/State/AppModel.swift",
            line: 541,
            value: ".sourceLost",
            guardDescription: "the machine's `.starting` legal-from set (was: `guard phase == .starting`)",
            from: .starting,
            action: .captureRestartFailed("boom"),
            to: .sourceLost,
            effects: [.postRestartFailed("boom")]
        ),
        // 7
        Site(
            number: 7,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 124,
            value: ".paused",
            guardDescription: "the machine's `.running` legal-from set (was: `guard phase == .running`)",
            from: .running,
            action: .pauseRequested,
            to: .paused,
            effects: [.stopCapture]
        ),
        // 8
        Site(
            number: 8,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 169,
            value: ".running",
            guardDescription: "the machine's `.paused` legal-from set (was: `guard phase == .paused`)",
            from: .paused,
            action: .resumeSucceeded,
            to: .running,
            effects: [.flushEngine]
        ),
        // 9
        Site(
            number: 9,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 175,
            value: ".sourceLost",
            guardDescription: "the machine's `.paused` legal-from set (was: `guard phase == .paused`)",
            from: .paused,
            action: .resumeFailed("boom"),
            to: .sourceLost,
            effects: [.postResumeFailed("boom")]
        ),
        // 10
        Site(
            number: 10,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 28,
            value: ".starting",
            guardDescription: "the machine's `.idle`/`.failed` legal-from set + the terminating latch"
                + " + openArchive == nil + !isCheckingModel",
            from: .idle,
            action: .startRequested,
            to: .starting,
            effects: [.awaitDictionary, .beginSession]
        ),
        // 10 — the `.failed` arm of the same switch
        Site(
            number: 10,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 28,
            value: ".starting",
            guardDescription: "the machine's `.idle`/`.failed` legal-from set + the terminating latch"
                + " + openArchive == nil + !isCheckingModel",
            from: .failed("boom"),
            action: .startRequested,
            to: .starting,
            effects: [.awaitDictionary, .beginSession]
        ),
        // 11
        Site(
            number: 11,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 46,
            value: ".failed(error.localizedDescription)",
            guardDescription: "the machine's `.starting` legal-from set (was: `guard self.phase == .starting`)",
            from: .starting,
            action: .beginFailed("boom"),
            to: .failed("boom"),
            effects: [.postSessionFailed("boom")]
        ),
        // 12 — the teardown the interrupted bring-up owes
        Site(
            number: 12,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 72,
            value: "(none — the phase stays)",
            guardDescription: "the machine's compensating branch (was: `guard phase == .starting else"
                + " { await sessionController.stop(); ... }`)",
            from: .stopping,
            action: .beginInterruptedByTeardown,
            to: .stopping,
            effects: [.tearDownSession]
        ),
        // 12 — the wind-back, after the teardown has landed
        Site(
            number: 12,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 79,
            value: ".idle",
            guardDescription: "the machine's wind-back (was: `if phase == .stopping { phase = .idle }`"
                + " after the teardown)",
            from: .stopping,
            action: .teardownCompleted,
            to: .idle,
            effects: []
        ),
        // 13
        Site(
            number: 13,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 83,
            value: ".needsModel",
            guardDescription: "guard started (begin() returned false), after the interruption check",
            from: .starting,
            action: .beginReturnedNoModel,
            to: .needsModel,
            effects: []
        ),
        // 14
        Site(
            number: 14,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 87,
            value: ".running",
            guardDescription: "the machine's `.starting` legal-from set",
            from: .starting,
            action: .beginSucceeded,
            to: .running,
            effects: [.activateTranslation, .startTimers, .armNoAudioWatchdog]
        ),
        // 15 — the `.running` arm
        Site(
            number: 15,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 239,
            value: ".stopping",
            guardDescription: "the machine's `.starting`/`.running`/`.paused`/`.sourceLost` legal-from set",
            from: .running,
            action: .stopRequested,
            to: .stopping,
            effects: [.stopCapture, .drainTranslation]
        ),
        // 15 — the `.paused` arm
        Site(
            number: 15,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 239,
            value: ".stopping",
            guardDescription: "the machine's `.starting`/`.running`/`.paused`/`.sourceLost` legal-from set",
            from: .paused,
            action: .stopRequested,
            to: .stopping,
            effects: [.stopCapture, .drainTranslation]
        ),
        // 15 — the `.sourceLost` arm
        Site(
            number: 15,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 239,
            value: ".stopping",
            guardDescription: "the machine's `.starting`/`.running`/`.paused`/`.sourceLost` legal-from set",
            from: .sourceLost,
            action: .stopRequested,
            to: .stopping,
            effects: [.stopCapture, .drainTranslation]
        ),
        // 16
        Site(
            number: 16,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 305,
            value: ".idle",
            guardDescription: "the machine's `.stopping`/`.idle` legal-from set (was unconditional, post-teardown)",
            from: .stopping,
            action: .stopCompleted,
            to: .idle,
            effects: stopCompletionBundle
        ),
        // 16 — the site-12 race: the phase was already wound back to idle
        Site(
            number: 16,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 305,
            value: ".idle",
            guardDescription: "the machine's `.stopping`/`.idle` legal-from set; reachable from .idle when site 12 won",
            from: .idle,
            action: .stopCompleted,
            to: .idle,
            effects: stopCompletionBundle
        ),
        // 17 — the `.running` arm
        Site(
            number: 17,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 333,
            value: ".stopping",
            guardDescription: "the machine's live-phase branch (was: `else if phase == .starting || .running"
                + " || .paused || .stopping || .sourceLost`)",
            from: .running,
            action: .terminationStarted,
            to: .stopping,
            effects: terminationTeardownBundle
        ),
        // 17 — the `.sourceLost` arm
        Site(
            number: 17,
            file: "Mimidasu/State/AppModel+Session.swift",
            line: 333,
            value: ".stopping",
            guardDescription: "the machine's live-phase branch (was: `else if phase == .starting || .running"
                + " || .paused || .stopping || .sourceLost`)",
            from: .sourceLost,
            action: .terminationStarted,
            to: .stopping,
            effects: terminationTeardownBundle
        )
    ]
}

/// The machine honours the production-site spec table.
struct ProductionWriteSiteSpecTests {

    /// Every one of the production sites appears in the spec table.
    @Test("the spec table covers all 17 production write sites")
    func specCoversAllSeventeenSites() {
        let covered = Set(ProductionSiteTable.sites.map { site in site.number })
        #expect(covered == Set(1 ... 17), "sites covered: \(covered.sorted())")
    }

    /// The machine reproduces today's phase outcome for every site.
    @Test("the machine reproduces today's phase outcome for every production site")
    func machineReproducesProductionOutcome() {
        for site in ProductionSiteTable.sites {
            var machine = SessionPhaseMachine(phase: site.from)
            let transition = machine.reduce(site.action)

            #expect(
                machine.phase == site.to,
                "site \(site.number) (\(site.file):\(site.line)) must land on \(site.to), landed on \(machine.phase)"
            )
            #expect(
                transition.effects == site.effects,
                "site \(site.number) (\(site.file):\(site.line)) must emit \(site.effects), emitted \(transition.effects)"
            )
        }
    }

    // MARK: - Guard preservation

    //
    // A guard is preserved when the action, arriving from a phase the
    // production guard does NOT admit, changes nothing. The two exceptions
    // are the compensating transitions, which must still not bring the
    // session up.

    /// The legal-from set of every action, read off the production guards.
    static let legalFrom: [String: [SessionPhase]] = [
        "startRequested": [.idle, .failed("boom")],
        "beginSucceeded": [.starting],
        "beginReturnedNoModel": [.starting],
        "beginFailed(String)": [.starting],
        "pauseRequested": [.running],
        "resumeRequested": [.paused],
        "resumeSucceeded": [.paused],
        "resumeFailed(String)": [.paused],
        "captureLost(String)": [.running, .starting],
        "captureRestartRequested": [.sourceLost, .paused],
        "captureRestartSucceeded": [.starting],
        "captureRestartFailed(String)": [.starting],
        "stopRequested": [.starting, .running, .paused, .sourceLost]
    ]

    /// The actions whose illegal arrival still owes a compensating effect.
    static let compensatingActions: Set<String> = [
        "beginSucceeded",
        "beginReturnedNoModel"
    ]

    /// The wind-back that lands after a raced teardown: production's
    /// `if phase == .stopping { phase = .idle }`. It is a **separate**
    /// action, because the wind-back must land after the teardown — moving
    /// it earlier would offer the user a Start while the old session is
    /// still being torn down.
    @Test("the wind-back is refused unless the phase is `.stopping`")
    func windBackNeedsTheStoppingPhase() {
        for from in SessionPhaseFixtures.all where from != .stopping {
            var machine = SessionPhaseMachine(phase: from)
            let transition = machine.reduce(.teardownCompleted)

            #expect(machine.phase == from, "\(from) must not move")
            #expect(transition.effects.isEmpty)
            #expect(!transition.isLegal)
        }

        var machine = SessionPhaseMachine(phase: .stopping)
        let transition = machine.reduce(.teardownCompleted)
        #expect(machine.phase == .idle)
        #expect(transition.isLegal)
    }

    @Test("every guard is preserved: an action from outside its legal-from set changes nothing")
    func everyGuardIsPreserved() {
        let actions: [(String, SessionAction)] = [
            ("startRequested", .startRequested),
            ("beginSucceeded", .beginSucceeded),
            ("beginReturnedNoModel", .beginReturnedNoModel),
            ("beginFailed(String)", .beginFailed("boom")),
            ("pauseRequested", .pauseRequested),
            ("resumeRequested", .resumeRequested),
            ("resumeSucceeded", .resumeSucceeded),
            ("resumeFailed(String)", .resumeFailed("boom")),
            ("captureLost(String)", .captureLost("stream died")),
            ("captureRestartRequested", .captureRestartRequested),
            ("captureRestartSucceeded", .captureRestartSucceeded),
            ("captureRestartFailed(String)", .captureRestartFailed("boom")),
            ("stopRequested", .stopRequested)
        ]

        for (name, action) in actions {
            guard let legal = Self.legalFrom[name] else {
                Issue.record("no legal-from set for \(name)")
                continue
            }
            for from in SessionPhaseFixtures.all where !legal.contains(from) {
                var machine = SessionPhaseMachine(phase: from)
                let effects = machine.reduce(action).effects

                // The `.paused` capture-lost deferral: no phase write, but
                // the error is parked for the resume path.
                if name == "captureLost(String)", from == .paused {
                    #expect(machine.phase == .paused)
                    #expect(effects == [.deferCaptureError("stream died")])
                    continue
                }

                #expect(
                    machine.phase == from,
                    "\(name) from \(from) must not move the phase (guard: \(legal))"
                )
                if Self.compensatingActions.contains(name) {
                    #expect(
                        effects == [.tearDownSession],
                        "\(name) from \(from) must still emit the compensating effect"
                    )
                } else {
                    #expect(
                        effects.isEmpty,
                        "\(name) from \(from) must be refused outright, emitted \(effects)"
                    )
                }
            }
        }
    }

    @Test("terminationStarted has no refused from-phase: every phase either stops or retires")
    func terminationHasNoRefusal() {
        for from in SessionPhaseFixtures.all {
            var machine = SessionPhaseMachine(phase: from)
            let effects = machine.reduce(.terminationStarted).effects

            #expect(machine.isTerminating, "\(from)")
            #expect(effects.contains(.retireWarmEngine), "\(from)")
            #expect(effects.contains(.postTerminationTeardownComplete), "\(from)")
            if from == .starting || from == .running || from == .paused || from == .sourceLost {
                #expect(machine.phase == .stopping, "\(from)")
                #expect(effects.contains(.finalizeLiveSession), "\(from)")
            } else {
                #expect(machine.phase == from, "\(from) must not move")
            }
        }
    }

    @Test("the capture-lost guard admits the deferred `.paused` case without a phase change")
    func captureLostDefersWhilePaused() {
        var machine = SessionPhaseMachine(phase: .paused)
        let effects = machine.reduce(.captureLost("stream died")).effects

        #expect(machine.phase == .paused, "the deferral must not move the phase")
        #expect(effects == [.deferCaptureError("stream died")])
    }

    @Test("the model-resolution guard never refuses the warm-up")
    func modelResolutionAlwaysWarmsUp() {
        for from in SessionPhaseFixtures.all {
            var machine = SessionPhaseMachine(phase: from)
            let effects = machine.reduce(.modelResolved(resolved: false)).effects
            #expect(effects == [.warmUpEngine], "\(from)")
        }
    }
}
