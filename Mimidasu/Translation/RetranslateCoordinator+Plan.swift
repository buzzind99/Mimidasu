import Foundation

extension RetranslateCoordinator {
    /// Builds the re-translate decision for one surface, target, and
    /// selection. Every fact is read from current observable state, so a view
    /// body that reads a derived member also observes the settings, probe
    /// evidence, live runtime (status and worker attachment), phase, and
    /// pending markers that can change the decision. The selection defaults
    /// to the persisted Settings choice; callers with an explicit picker
    /// selection pass it in.
    func plan(
        surface: RetranslateSurface,
        target: TargetLanguage,
        selection: RetranslateEngine? = nil
    ) -> RetranslatePlan {
        let selection = selection ?? settings.retranslateEngine
        let liveSnapshot = liveFacts
        return RetranslatePlan(
            context: RetranslateContext(
                surface: surface,
                target: target,
                selection: selection,
                effectiveSelection: tierAvailability.effectiveTier(
                    selection, targetCode: target.code
                ),
                tier: RetranslateTierFacts(
                    highFidelityOffered: tierAvailability.offersHighFidelity(for: target.code),
                    highFidelityKnownUnavailable: tierAvailability.knownUnavailable(for: target.code)
                ),
                live: liveSnapshot,
                keys: RetranslateKeyFacts(
                    keyed: Set(
                        TranslationProvider.allCases.filter { provider in
                            settings.hasKey(for: provider)
                        }
                    ),
                    configured: Set(
                        TranslationProvider.allCases.filter { provider in
                            settings.isConfigured(for: provider)
                        }
                    )
                ),
                row: RetranslateRowFacts(
                    pendingIndexes: pendingRetranslations,
                    archiveJobRunning: host?.archiveTranslationRunning ?? false,
                    showsMarker: settings.showsRetranslateMarker,
                    probeTargetCode: live?.appleHighFidelityProbe.targetCode
                )
            )
        )
    }

    /// The row's retry affordance and provenance marker for one entry.
    func rowPlan(
        for entry: SessionEntry,
        surface: RetranslateSurface,
        target: TargetLanguage
    ) -> RetranslateRowPlan {
        plan(surface: surface, target: target).row(for: entry)
    }

    /// The live session's identity, worker attachment, and phase. The
    /// attachment reads the observable mirror the queue's workerChanged
    /// callback keeps in sync with the queue, and falls back to the queue
    /// itself when there is no live session.
    private var liveFacts: RetranslateLiveFacts {
        RetranslateLiveFacts(
            activeEngineKind: activeEngineKind,
            runsFast: liveSessionRunsKind(.appleFast),
            runsHighFidelity: liveSessionRunsKind(.appleHighFidelity),
            attachedProvider: live?.activeExternalProvider,
            workerAttached: live?.runtime.workerAttached ?? queue.hasWorker,
            status: live?.runtime.status ?? .idle,
            phaseIsLive: SessionPhaseMachine.isLive(sessionPhase)
        )
    }
}
