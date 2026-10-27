import Foundation

/// Routes tap-lookup feedback from the session to the app's notice and toast
/// chrome: a no-hit warning pill naming the tapped surface, or a dictionary
/// lookup fault toast carrying the typed error's message. The session decides
/// which feedback an effect deserves; this surface owns the copy and style.
extension AppModel: TapLookupFeedbackSink {
    func tapLookupDidWarnNoHit(surface: String) {
        notices.post(
            message: "No dictionary entry for \"\(surface)\"", tone: .warning
        )
    }

    func tapLookupDidFail(_ fault: DictionaryError) {
        toasts.post(
            key: ToastKey.dictionaryLookup, style: .yellowAuto,
            title: "Dictionary lookup failed", body: fault.localizedDescription
        )
    }
}
