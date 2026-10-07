import Foundation

/// ASR model-selection surface of `AppModel` (file split for the lint
/// gate): availability refresh, switching the active choice, and adopting
/// a freshly downloaded model.
extension AppModel {

    // MARK: - Availability

    /// Re-checks both model choices and moves `idle`↔`needsModel` by the
    /// active choice's result. The resolve (existence + SHA-256 verify,
    /// hashing up to ~1.2 GB) runs off-main and the result is hopped back
    /// here; `isCheckingModel` gates Start while the check is in flight.
    /// `resolve` overrides the stored resolver for tests; by default the
    /// resolver injected at init drives the lookup. The active choice's URL
    /// also lands in `modelURL` and every choice's result in
    /// `modelAvailability` (Settings rows).
    func refreshModelAvailability(
        resolve: (@Sendable (ASRModelChoice) -> URL?)? = nil
    ) async {
        let resolve = resolve ?? modelResolve
        isCheckingModel = true
        let selected = asrModelSettings.selected
        let resolved = await Task.detached(priority: .userInitiated) { () -> [ASRModelChoice: URL] in
            // Both choices resolve concurrently: each verify hashes up to
            // ~1.2 GB, and parallel keeps the wall time at the slower one
            // instead of the sum.
            await withTaskGroup(of: (ASRModelChoice, URL?).self) { group in
                for choice in ASRModelChoice.allCases {
                    group.addTask { (choice, resolve(choice)) }
                }
                var availability: [ASRModelChoice: URL] = [:]
                for await (choice, url) in group {
                    availability[choice] = url
                }
                return availability
            }
        }.value
        modelAvailability = resolved
        let url = resolved[selected]
        modelURL = url
        if url == nil, phase == .idle {
            phase = .needsModel
        } else if url != nil, phase == .needsModel {
            phase = .idle
        }
        sessionController.warmUpIfNeeded(modelURL: url)
        isCheckingModel = false
    }

    // MARK: - Selection

    /// Switches the active ASR model. Only a downloaded + verified model can
    /// be selected (its resolve result must be cached), and a running or
    /// starting session must never be re-modelled mid-flight — the change
    /// applies at the next session start, like the translation provider.
    /// Persisting re-resolves (updating `modelURL` and `phase`) and re-warms
    /// the new engine in the background (`warmUpIfNeeded` re-arms on the new
    /// path).
    func selectModel(_ choice: ASRModelChoice) {
        guard phase != .running, phase != .starting else { return }
        guard modelAvailability[choice] != nil else { return }
        asrModelSettings.select(choice)
        modelSelectionRefresh = Task { await refreshModelAvailability() }
    }

    /// Called after a Settings download of `choice` completes (the download
    /// button is explicit intent): re-resolves availability so the new file
    /// is hashed + verified, then auto-selects it.
    func adoptDownloadedModel(_ choice: ASRModelChoice) async {
        await refreshModelAvailability()
        selectModel(choice)
        // `selectModel` re-resolves in a tracked task; awaiting it here (one
        // extra pass, never overlapping `refreshModelAvailability`) means the
        // new model is live (modelURL + warm-up) before we return.
        await modelSelectionRefresh?.value
    }
}
