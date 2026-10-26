import Foundation
@testable import Mimidasu

/// An idle `AppModel` over isolated settings for the State suites: fresh
/// `UserDefaults` suites and in-memory stores, a hermetic high-fidelity probe,
/// and a stubbed launch model resolve. Each parameter defaults to the isolated
/// fixture; pass an explicit one where a test needs its own.
@MainActor
func makeIdleModel(
    suite: String,
    translationSettings: TranslationSettings? = nil,
    asrModelSettings: ASRModelSettings? = nil,
    favorites: FavoritesStore? = nil,
    archive: ArchiveStore? = nil,
    translationTransport: HTTPTranslationTransport? = nil,
    highFidelityProbe: @escaping @Sendable (String) async -> Bool = { _ in false },
    jmDictLookup: JMDictLookup? = nil,
    initialModelResolve: @escaping @Sendable (ASRModelChoice) -> URL? = { _ in nil },
    willTerminateNotifications: NotificationCenter = .default
) -> AppModel {
    AppModel(
        translationSettings: translationSettings ?? isolatedTranslationSettings(suite: suite),
        asrModelSettings: asrModelSettings ?? isolatedASRModelSettings(suite: suite),
        favorites: favorites ?? isolatedFavorites(),
        archive: archive ?? isolatedArchive(),
        translationTransport: translationTransport,
        highFidelityProbe: highFidelityProbe,
        jmDictLookup: jmDictLookup,
        initialModelResolve: initialModelResolve,
        willTerminateNotifications: willTerminateNotifications
    )
}

/// A ja sentence with the shape the State suites use.
func makeSentence(index: Int = 0, text: String = "テスト") -> Sentence {
    Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
}
