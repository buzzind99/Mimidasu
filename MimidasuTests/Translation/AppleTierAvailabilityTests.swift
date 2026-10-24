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

    @Test("a landing writes the installed flag and its pair")
    func landingWritesEvidence() {
        let sut = makeSUT()

        sut.land(installed: true, targetCode: pair)

        #expect(sut.probe.installed)
        #expect(sut.probe.targetCode == pair)
    }

    @Test("a landing reports evidence for its pair only")
    func landingIsPairScoped() {
        let sut = makeSUT()

        sut.land(installed: true, targetCode: pair)

        #expect(sut.probeLanded(for: pair))
        #expect(!sut.probeLanded(for: foreignPair))
    }

    @Test("a not-installed landing reports unavailability for its pair only")
    func unavailabilityIsPairScoped() {
        let sut = makeSUT()

        sut.land(installed: false, targetCode: pair)

        #expect(sut.knownUnavailable(for: pair))
        #expect(!sut.knownUnavailable(for: foreignPair))
    }

    @Test("an installed landing is not unavailability")
    func installedLandingIsNotUnavailable() {
        let sut = makeSUT()

        sut.land(installed: true, targetCode: pair)

        #expect(!sut.knownUnavailable(for: pair))
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

    @Test("high fidelity is offered with no evidence")
    func offersWithNoEvidence() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("strategy selection requires macOS 26.4")
        }
        let sut = makeSUT()

        #expect(sut.offersHighFidelity(for: pair))
    }

    @Test("a not-installed landing withdraws the offer for its pair")
    func notInstalledWithdrawsOffer() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("strategy selection requires macOS 26.4")
        }
        let sut = makeSUT()

        sut.land(installed: false, targetCode: pair)

        #expect(!sut.offersHighFidelity(for: pair))
        #expect(sut.offersHighFidelity(for: foreignPair))
    }

    @Test("an installed landing keeps the offer")
    func installedKeepsOffer() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("strategy selection requires macOS 26.4")
        }
        let sut = makeSUT()

        sut.land(installed: true, targetCode: pair)

        #expect(sut.offersHighFidelity(for: pair))
    }

    @Test("identity is unknown before the pair's probe lands")
    func identityUnknownBeforeLanding() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("strategy selection requires macOS 26.4")
        }
        let sut = makeSUT()

        #expect(!sut.identityKnown(for: pair))
    }

    @Test("identity is known after the pair's probe lands")
    func identityKnownAfterLanding() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("strategy selection requires macOS 26.4")
        }
        let sut = makeSUT()

        sut.land(installed: false, targetCode: pair)

        #expect(sut.identityKnown(for: pair))
        #expect(!sut.identityKnown(for: foreignPair))
    }

    // MARK: - Availability

    @Test("availability is false before a landing")
    func unavailableBeforeLanding() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("availability requires macOS 26.4")
        }
        let sut = makeSUT()

        #expect(!sut.available(for: pair))
    }

    @Test("availability is false when the landing is not installed")
    func unavailableWhenNotInstalled() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("availability requires macOS 26.4")
        }
        let sut = makeSUT()

        sut.land(installed: false, targetCode: pair)

        #expect(!sut.available(for: pair))
    }

    @Test("availability is true when the landing is installed")
    func availableWhenInstalled() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("availability requires macOS 26.4")
        }
        let sut = makeSUT()

        sut.land(installed: true, targetCode: pair)

        #expect(sut.available(for: pair))
    }

    @Test("availability is scoped to the pair's own landing")
    func availabilityIsPairScoped() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("availability requires macOS 26.4")
        }
        let sut = makeSUT()

        sut.land(installed: true, targetCode: foreignPair)

        #expect(!sut.available(for: pair))
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

    @Test("a not-installed landing degrades the high-fidelity tier")
    func notInstalledDegradesTier() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("strategy selection requires macOS 26.4")
        }
        let sut = makeSUT()

        sut.land(installed: false, targetCode: pair)

        #expect(sut.effectiveTier(.appleHighFidelity, targetCode: pair) == .appleFast)
    }

    @Test("a not-installed landing degrades the high-fidelity kind")
    func notInstalledDegradesKind() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("strategy selection requires macOS 26.4")
        }
        let sut = makeSUT()

        sut.land(installed: false, targetCode: pair)

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

    @Test("applies the high-fidelity strategy on macOS 26.4+")
    func appliesHighFidelityStrategy() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("preferredStrategy requires macOS 26.4")
        }
        let sut = makeSUT()
        var config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: pair)
        )

        sut.applyPreferredStrategy(to: &config, highFidelity: true)

        #expect(config.preferredStrategy == .highFidelity)
    }

    @Test("applies the low-latency strategy on macOS 26.4+")
    func appliesLowLatencyStrategy() throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("preferredStrategy requires macOS 26.4")
        }
        let sut = makeSUT()
        var config = TranslationSession.Configuration(
            source: Locale.Language(identifier: "ja"),
            target: Locale.Language(identifier: pair)
        )

        sut.applyPreferredStrategy(to: &config, highFidelity: false)

        #expect(config.preferredStrategy == .lowLatency)
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
