import Foundation
@testable import Mimidasu
import Synchronization
import Testing
import Translation

/// Drives the tier-availability module directly: the pair-scoped landing
/// evidence, the offer and identity truth tables, the high-fidelity degrade,
/// the strategy application, and the sequence that drops superseded probe
/// landings.
@MainActor
@Suite("Apple tier availability")
struct AppleTierAvailabilityTests {

    private let pair = "fr"
    private let foreignPair = "de"

    /// Evidence layouts the tier and kind resolution must agree on.
    enum Evidence: String, CaseIterable, Sendable {
        case unlanded
        case installedForPair
        case notInstalledForPair
        case installedForForeignPair
        case notInstalledForForeignPair
    }

    private func makeSUT(installed: Bool = false) -> AppleTierAvailability {
        AppleTierAvailability(check: { _ in installed })
    }

    private func seed(_ evidence: Evidence, on sut: AppleTierAvailability) {
        switch evidence {
        case .unlanded:
            break
        case .installedForPair:
            sut.land(installed: true, targetCode: pair)
        case .notInstalledForPair:
            sut.land(installed: false, targetCode: pair)
        case .installedForForeignPair:
            sut.land(installed: true, targetCode: foreignPair)
        case .notInstalledForForeignPair:
            sut.land(installed: false, targetCode: foreignPair)
        }
    }

    // MARK: - Landed evidence

    @Test("evidence starts absent for every pair")
    func evidenceStartsAbsent() {
        let sut = makeSUT()

        #expect(!sut.probe.installed)
        #expect(sut.probe.targetCode == nil)
    }

    // MARK: - Offer and identity

    @Test("strategy support follows the OS availability gate")
    func strategySupportFollowsOSGate() throws {
        guard #available(macOS 26.4, *) else {
            #expect(!AppleTierAvailability.supportsStrategySelection)
            try Test.cancel("strategy selection requires macOS 26.4")
        }

        #expect(AppleTierAvailability.supportsStrategySelection)
    }

    @Test(
        "the offer and unavailability tables follow the landed evidence",
        arguments: [
            (Evidence.unlanded, true, true, false),
            (Evidence.installedForPair, true, true, false),
            (Evidence.notInstalledForPair, false, true, true),
            (Evidence.installedForForeignPair, true, true, false),
            (Evidence.notInstalledForForeignPair, true, false, false)
        ]
    )
    func offerAndUnavailabilityFollowEvidence(
        evidence: Evidence, offers: Bool, offersForeign: Bool, knownUnavailable: Bool
    ) throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("high-fidelity offers require macOS 26.4")
        }
        let sut = makeSUT()
        seed(evidence, on: sut)

        #expect(sut.offersHighFidelity(for: pair) == offers)
        #expect(sut.offersHighFidelity(for: foreignPair) == offersForeign)
        #expect(sut.knownUnavailable(for: pair) == knownUnavailable)
    }

    @Test(
        "landing evidence is scoped to its own pair",
        arguments: [
            (Evidence.unlanded, false, true, false),
            (Evidence.installedForPair, true, true, false),
            (Evidence.notInstalledForPair, true, true, false),
            (Evidence.installedForForeignPair, false, false, false),
            (Evidence.notInstalledForForeignPair, false, false, true)
        ]
    )
    func landingEvidenceIsPairScoped(
        evidence: Evidence, landsForPair: Bool, foreignIdentityAbsent: Bool, foreignUnavailable: Bool
    ) throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("pair identity requires macOS 26.4")
        }
        let sut = makeSUT()
        seed(evidence, on: sut)

        #expect(sut.probeLanded(for: pair) == landsForPair)
        #expect(sut.identityKnown(for: pair) == landsForPair)
        #expect(!sut.identityKnown(for: foreignPair) == foreignIdentityAbsent)
        #expect(sut.knownUnavailable(for: foreignPair) == foreignUnavailable)
    }

    // MARK: - Availability

    @Test(
        "availability follows the pair's own installed landing",
        arguments: [
            (Evidence.unlanded, false),
            (Evidence.installedForPair, true),
            (Evidence.notInstalledForPair, false),
            (Evidence.installedForForeignPair, false),
            (Evidence.notInstalledForForeignPair, false)
        ]
    )
    func availabilityFollowsThePairsOwnLanding(evidence: Evidence, available: Bool) throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("availability requires macOS 26.4")
        }
        let sut = makeSUT()
        seed(evidence, on: sut)

        #expect(sut.available(for: pair) == available)
    }

    // MARK: - Resolution

    @Test(
        "non-Apple tiers pass through unchanged",
        arguments: [
            RetranslateEngine.session, .appleFast, .google, .deepl, .openrouter,
            .openai, .anthropic, .moonshot, .zai, .deepseek, .xai
        ]
    )
    func nonAppleTiersPassThrough(tier: RetranslateEngine) {
        let sut = makeSUT()

        sut.land(installed: false, targetCode: pair)

        #expect(sut.effectiveTier(tier, targetCode: pair) == tier)
    }

    @Test(
        "non-Apple kinds pass through unchanged",
        arguments: [
            TranslationEngineKind.appleFast, .google, .deepl, .openrouter,
            .openai, .anthropic, .moonshot, .zai, .deepseek, .xai
        ]
    )
    func nonAppleKindsPassThrough(kind: TranslationEngineKind) {
        let sut = makeSUT()

        sut.land(installed: false, targetCode: pair)

        #expect(sut.effectiveKind(kind, targetCode: pair) == kind)
    }

    @Test("a high-fidelity pick passes through with no evidence")
    func highFidelityPassesThroughWithoutEvidence() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("strategy selection requires macOS 26.4")
        }
        let sut = makeSUT()

        #expect(sut.effectiveTier(.appleHighFidelity, targetCode: pair) == .appleHighFidelity)
        #expect(sut.effectiveKind(.appleHighFidelity, targetCode: pair) == .appleHighFidelity)
    }

    @Test("a high-fidelity pick passes through when installed for the pair")
    func highFidelityPassesThroughWhenInstalled() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("strategy selection requires macOS 26.4")
        }
        let sut = makeSUT()

        sut.land(installed: true, targetCode: pair)

        #expect(sut.effectiveTier(.appleHighFidelity, targetCode: pair) == .appleHighFidelity)
        #expect(sut.effectiveKind(.appleHighFidelity, targetCode: pair) == .appleHighFidelity)
    }

    @Test("a not-installed landing degrades both high-fidelity spellings")
    func notInstalledLandingDegradesBothSpellings() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("strategy selection requires macOS 26.4")
        }
        let sut = makeSUT()

        sut.land(installed: false, targetCode: pair)

        #expect(sut.effectiveTier(.appleHighFidelity, targetCode: pair) == .appleFast)
        #expect(sut.effectiveKind(.appleHighFidelity, targetCode: pair) == .appleFast)
    }

    @Test("another pair's unavailability keeps high fidelity")
    func foreignUnavailabilityKeepsHighFidelity() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("strategy selection requires macOS 26.4")
        }
        let sut = makeSUT()

        sut.land(installed: false, targetCode: foreignPair)

        #expect(sut.effectiveTier(.appleHighFidelity, targetCode: pair) == .appleHighFidelity)
        #expect(sut.effectiveKind(.appleHighFidelity, targetCode: pair) == .appleHighFidelity)
    }

    @Test("tier and kind degrade in agreement across evidence states", arguments: Evidence.allCases)
    func tierAndKindAgree(evidence: Evidence) {
        let sut = makeSUT()

        seed(evidence, on: sut)

        let tier = sut.effectiveTier(.appleHighFidelity, targetCode: pair)
        let kind = sut.effectiveKind(.appleHighFidelity, targetCode: pair)

        #expect((kind == .appleFast) == (tier == .appleFast))
    }

    // MARK: - Probe lifecycle

    @Test("beginProbe lands the probe's answer for its pair")
    func beginProbeLandsAnswer() async {
        let sut = makeSUT(installed: true)

        sut.beginProbe(for: pair)

        #expect(await pollUntil { sut.probeLanded(for: pair) }, "the probe lands")
        #expect(sut.probe.installed, "the landing records the answer")
        #expect(sut.probe.targetCode == pair, "the landing records its pair")
    }

    @Test("beginProbe clears evidence synchronously and drops a superseded landing")
    func supersededLandingIsDropped() async {
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        let probeCalls = Mutex(0)
        let sut = AppleTierAvailability(check: { _ in
            let call = probeCalls.withLock { calls in
                calls += 1
                return calls
            }
            guard call == 1 else { return true }
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
            return false
        })

        sut.land(installed: true, targetCode: pair)
        sut.beginProbe(for: pair)

        #expect(!sut.probe.installed, "beginProbe clears the evidence synchronously")
        #expect(sut.probe.targetCode == nil)
        #expect(
            await pollUntil { probeCalls.withLock { calls in calls >= 1 } },
            "the first probe is airborne"
        )

        sut.beginProbe(for: pair)
        #expect(await pollUntil { sut.probe == (true, pair) }, "the fresh probe lands")

        gate.yield(())
        let staleOverwrote = await pollUntil(timeout: 0.5) {
            sut.probe == (false, pair)
        }
        #expect(!staleOverwrote, "the superseded landing is dropped")
    }

    @Test("a superseded airborne probe never lands after a session boundary")
    func sessionBoundaryDropsAirborneProbe() async {
        let (gateStream, gate) = AsyncStream<Void>.makeStream()
        let sut = AppleTierAvailability(check: { _ in
            var iterator = gateStream.makeAsyncIterator()
            _ = await iterator.next()
            return true
        })

        sut.beginProbe(for: pair)
        sut.supersedeInFlightProbe()
        gate.yield(())
        let staleLanded = await pollUntil(timeout: 0.5) {
            sut.probe.installed
        }

        #expect(!staleLanded, "the session boundary drops the airborne landing")
        #expect(sut.probe.targetCode == nil)
    }

    // MARK: - Strategy application

    @Test(
        "the preferred strategy follows the requested fidelity on macOS 26.4+",
        arguments: [true, false]
    )
    func appliesRequestedStrategy(highFidelity: Bool) throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("preferredStrategy requires macOS 26.4")
        }
        let sut = makeSUT()
        var config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: pair)
        )

        sut.applyPreferredStrategy(to: &config, highFidelity: highFidelity)

        #expect(config.preferredStrategy == (highFidelity ? .highFidelity : .lowLatency))
    }

    @Test("the configuration follows the OS strategy gate")
    func configurationFollowsOSGate() {
        let sut = makeSUT()
        var config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: pair)
        )
        let original = config

        sut.applyPreferredStrategy(to: &config, highFidelity: true)

        if #available(macOS 26.4, *) {
            #expect(config.preferredStrategy == .highFidelity)
        } else {
            #expect(config == original)
        }
    }
}
