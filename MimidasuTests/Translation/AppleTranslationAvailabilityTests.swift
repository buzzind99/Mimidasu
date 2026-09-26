import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Tests `AppleTranslationAvailability` against a fake probe: `ja` dropped,
/// regional variants normalized and deduped, unknown codes dropped, the
/// catalog sorted alphabetically by display name.
@MainActor
@Suite("AppleTranslationAvailability")
struct AppleTranslationAvailabilityTests {

    // MARK: - Helpers

    private func makeLoaded(_ languages: [String]) async -> AppleTranslationAvailability {
        let availability = AppleTranslationAvailability(probe: {
            languages.map { code in Locale.Language(identifier: code) }
        })
        await availability.refresh()
        return availability
    }

    /// Locale-robust ordering assertion: sorted by localized display name
    /// (which varies with the test host's locale), A first.
    private func assertOrdered(_ targets: [TargetLanguage]) {
        let sorted = targets.sorted { first, second in first.displayName < second.displayName }
        #expect(targets == sorted, "display-name order (A first)")
    }

    // MARK: - refresh

    @Test("refresh loads the picker catalog from the probe")
    func refreshLoadsTargets() async {
        let availability = await makeLoaded(["ja", "en-US", "fr", "zh-Hans-CN"])

        #expect(availability.isLoaded)
        assertOrdered(availability.targets)
        #expect(Set(availability.targets.map(\.code)) == ["en", "fr", "zh-Hans"])
    }

    @Test("ja and its regions never appear as targets")
    func jaDropped() async {
        let availability = await makeLoaded(["ja", "ja-JP", "en", "th"])

        #expect(Set(availability.targets.map(\.code)) == ["en", "th"])
    }

    @Test("regional variants normalize and dedupe onto their base code")
    func regionalVariantsNormalize() async {
        let availability = await makeLoaded([
            "en-US", "en-GB", "zh-Hans-CN", "zh-Hant-TW", "pt-BR", "pt"
        ])

        assertOrdered(availability.targets)
        #expect(Set(availability.targets.map(\.code)) == ["en", "pt", "zh-Hans", "zh-Hant"])
    }

    @Test("codes with no metadata entry are dropped")
    func unknownCodesDropped() async {
        let availability = await makeLoaded(["en", "xx-Qabs", "sr-Cyrl", "yue"])

        #expect(availability.targets.map(\.code) == ["en"])
    }

    @Test("an empty probe leaves an empty but loaded catalog")
    func emptyProbeLoadsEmpty() async {
        let availability = await makeLoaded([])

        #expect(availability.isLoaded)
        #expect(availability.targets.isEmpty)
    }

    // MARK: - refreshIfNeeded

    @Test("refreshIfNeeded probes only while unloaded")
    func refreshIfNeededProbesOnceWhenLoaded() async {
        let probeCount = Mutex(0)
        let availability = AppleTranslationAvailability(probe: {
            probeCount.withLock { count in count += 1 }
            return [Locale.Language(identifier: "en")]
        })

        await availability.refreshIfNeeded()
        await availability.refreshIfNeeded()

        #expect(probeCount.withLock { count in count } == 1, "a loaded catalog skips the probe")
        #expect(availability.targets.map(\.code) == ["en"])
    }

    @Test("refresh re-probes unconditionally")
    func refreshReprobes() async {
        let probeCount = Mutex(0)
        let availability = AppleTranslationAvailability(probe: {
            probeCount.withLock { count in count += 1 }
            return [Locale.Language(identifier: "en")]
        })

        await availability.refresh()
        await availability.refresh()

        #expect(probeCount.withLock { count in count } == 2)
    }

    /// Smoke-runs the real `LanguageAvailability` probe so the production
    /// default stays wired: whatever this OS reports, the catalog loads and
    /// every survivor is a known entry (unknowns dropped, not degraded).
    @Test("the default probe loads a catalog of known entries")
    func defaultProbeLoadsKnownEntries() async {
        let availability = AppleTranslationAvailability()
        await availability.refresh()

        #expect(availability.isLoaded)
        let known = Set(TargetLanguage.known)
        for target in availability.targets {
            #expect(known.contains(target), "\(target.code) must be a table entry")
        }
    }
}
