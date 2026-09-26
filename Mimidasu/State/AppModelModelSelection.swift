import Foundation

/// ASR model-selection surface of `AppModel` (file split for the lint
/// gate): switching the active choice and adopting a freshly downloaded
/// model.
extension AppModel {
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
