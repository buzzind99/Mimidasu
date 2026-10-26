import Foundation
@testable import Mimidasu
import Testing

/// Tests `ASRModelSettings` persistence over isolated `UserDefaults` suites:
/// the production default, persisted round-trip,
/// and the stable raw-value contract the storage payload relies on.
@MainActor
@Suite("ASRModelSettings")
struct ASRModelSettingsTests {

    // MARK: - Defaults

    @Test("a fresh selection defaults to Lite")
    func defaultsToLite() {
        let settings = isolatedASRModelSettings(suite: "test.ASRModelSettings")

        #expect(settings.selected == .lite)
    }

    @Test("an unknown persisted raw value degrades to Lite")
    func unknownRawValueDegradesToLite() throws {
        let defaults = try #require(UserDefaults(suiteName: "test.ASRModelSettings.\(UUID().uuidString)"))
        defaults.set("bogus", forKey: "asr.model")

        let settings = ASRModelSettings(defaults: defaults)

        #expect(settings.selected == .lite)
    }

    // MARK: - Persistence

    @Test("selections round-trip through the stable storage payload and overwrite each other")
    func selectionsRoundTripThroughStablePayload() throws {
        #expect(ASRModelChoice.lite.rawValue == "lite")
        #expect(ASRModelChoice.full.rawValue == "full")

        let defaults = try #require(UserDefaults(suiteName: "test.ASRModelSettings.\(UUID().uuidString)"))

        let first = ASRModelSettings(defaults: defaults)
        first.select(.full)
        #expect(first.selected == .full)
        #expect(defaults.string(forKey: "asr.model") == "full", "the storage key is stable")

        let second = ASRModelSettings(defaults: defaults)
        #expect(second.selected == .full, "a selection persists across instances over the same suite")

        first.select(.lite)
        #expect(defaults.string(forKey: "asr.model") == "lite")

        let third = ASRModelSettings(defaults: defaults)
        #expect(third.selected == .lite, "a Lite selection overwrites a persisted Full selection")
    }
}
