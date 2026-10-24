import Foundation
@testable import Mimidasu
import Synchronization
import Testing
import Translation

/// Covers the coordinator's compatible-mode persistence: a live downgrade is
/// cached for future engines, and a fast-mode probe clears a stale entry.
@MainActor
@Suite("TranslationSessionCoordinator cache")
struct TranslationSessionCoordinatorCacheTests {
    @Test("a live downgrade is persisted for the effective model")
    func liveDowngradePersists() async throws {
        let settings = makeSettings()
        let attempts = Mutex(0)
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            let status = attempt == 1 ? 400 : 200
            let body = status == 200
                ? Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8)
                : Data()
            return (body, Self.response(for: request, status: status))
        }
        let coordinator = makeCoordinator(settings: settings, transport: transport)

        let engine = try #require(coordinator.makeExternalEngine(for: .openai))
        _ = try await engine.translate(["こんにちは"])

        let model = settings.effectiveModel(for: .openai)
        #expect(settings.isCompatibleMode(for: .openai))
        #expect(settings.compatibleModes[.openai] == model)
    }

    @Test("a successful fast-mode probe clears a stale cache entry")
    func fastProbeClearsCache() async {
        let settings = makeSettings()
        let model = settings.effectiveModel(for: .openai)
        settings.setCompatibleMode(for: .openai, model: model)
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            (
                Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8),
                Self.response(for: request, status: 200)
            )
        }
        let coordinator = makeCoordinator(settings: settings, transport: transport)

        let verified = await coordinator.verifyModel("", for: .openai)

        #expect(verified)
        #expect(settings.compatibleModes[.openai] == nil)
    }

    @Test("a model probe sends the trimmed draft, not the stored model")
    func modelProbeSendsDraft() async throws {
        let settings = makeSettings()
        let bodies = Mutex([Data]())
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            bodies.withLock { log in log.append(request.httpBody ?? Data()) }
            return (
                Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8),
                Self.response(for: request, status: 200)
            )
        }
        let coordinator = makeCoordinator(settings: settings, transport: transport)

        let verified = await coordinator.verifyModel("  gpt-6-sol  ", for: .openai)

        #expect(verified)
        let body = try #require(bodies.withLock { log in log.first })
        let object = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(object["model"] as? String == "gpt-6-sol")
    }

    @Test("a superseded probe cannot stage a provider switch")
    func supersededProbeDoesNotStageSelection() async {
        let settings = makeSettings()
        settings.select(.apple)
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            await withCheckedContinuation { continuation in
                gate.withLock { stored in stored = continuation }
            }
            return (
                Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8),
                Self.response(for: request, status: 200)
            )
        }
        let coordinator = makeCoordinator(settings: settings, transport: transport)

        let probe = Task { await coordinator.verifyAndSelect(.openai) }
        let started = await pollUntil(timeout: 5) {
            gate.withLock { stored in stored != nil }
        }
        #expect(started, "the probe reached the transport")
        guard started else { return }

        coordinator.noteProviderIntent()
        gate.withLock { stored in
            stored?.resume()
            stored = nil
        }

        let verified = await probe.value

        #expect(verified == .superseded)
        #expect(
            settings.testResult(for: .openai) == .success,
            "the intent-superseded probe still records its credential result"
        )
        #expect(coordinator.providerAwaitingDisclosure == nil)
        #expect(settings.selectedProvider == .apple)
    }

    @Test("a probe superseded by a later probe of the same provider writes nothing")
    func laterSameProviderProbeWritesNothing() async {
        let settings = makeSettings()
        let attempts = Mutex(0)
        let gates = Mutex([CheckedContinuation<Void, Never>]())
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            await withCheckedContinuation { continuation in
                gates.withLock { stored in stored.append(continuation) }
            }
            let status = attempt == 1 ? 400 : 200
            let body = status == 200
                ? Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8)
                : Data()
            return (body, Self.response(for: request, status: status))
        }
        let coordinator = makeCoordinator(settings: settings, transport: transport)

        let first = Task { await coordinator.verifyModel("", for: .openai) }
        let firstStarted = await pollUntil(timeout: 5) {
            gates.withLock { stored in stored.count == 1 }
        }
        #expect(firstStarted, "the first probe reached the transport")
        guard firstStarted else { return }

        let second = Task { await coordinator.verifyModel("", for: .openai) }
        let secondStarted = await pollUntil(timeout: 5) {
            gates.withLock { stored in stored.count == 2 }
        }
        #expect(secondStarted, "the second probe reached the transport")
        guard secondStarted else { return }

        gates.withLock { stored in
            stored.removeFirst().resume()
        }
        let retried = await pollUntil(timeout: 5) {
            gates.withLock { stored in stored.count == 2 }
        }
        #expect(retried, "the superseded probe's compatible retry reached the transport")
        guard retried else { return }

        gates.withLock { stored in
            stored.removeLast().resume()
        }

        let firstVerified = await first.value

        #expect(!firstVerified)
        #expect(settings.testResult(for: .openai) == nil, "the superseded probe records nothing")
        #expect(settings.compatibleModes[.openai] == nil, "no cache is written")

        gates.withLock { stored in
            stored.removeFirst().resume()
        }

        let secondVerified = await second.value

        #expect(secondVerified, "the superseding probe still lands its result")
    }

    @Test("a probe superseded by key removal writes nothing")
    func removedKeyProbeWritesNothing() async {
        let settings = makeSettings()
        let attempts = Mutex(0)
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            await withCheckedContinuation { continuation in
                gate.withLock { stored in stored = continuation }
            }
            let status = attempt == 1 ? 400 : 200
            let body = status == 200
                ? Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8)
                : Data()
            return (body, Self.response(for: request, status: status))
        }
        let coordinator = makeCoordinator(settings: settings, transport: transport)

        let probe = Task { await coordinator.verifyModel("", for: .openai) }
        let started = await pollUntil(timeout: 5) {
            gate.withLock { stored in stored != nil }
        }
        #expect(started, "the probe reached the transport")
        guard started else { return }

        gate.withLock { stored in
            stored?.resume()
            stored = nil
        }
        let retried = await pollUntil(timeout: 5) {
            gate.withLock { stored in stored != nil }
        }
        #expect(retried, "the compatible retry reached the transport")
        guard retried else { return }

        settings.removeKey(for: .openai)
        gate.withLock { stored in
            stored?.resume()
            stored = nil
        }

        let verified = await probe.value

        #expect(!verified)
        #expect(settings.testResult(for: .openai) == nil, "no success lands after removal")
        #expect(settings.compatibleModes[.openai] == nil, "no cache is resurrected")
        #expect(settings.selectedProvider == .apple)
    }

    @Test("a live downgrade learned after the model changed is not cached")
    func staleLiveDowngradeDropped() async throws {
        let settings = makeSettings()
        let attempts = Mutex(0)
        let gate = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            if attempt == 1 {
                return (Data(), Self.response(for: request, status: 400))
            }
            await withCheckedContinuation { continuation in
                gate.withLock { stored in stored = continuation }
            }
            return (
                Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8),
                Self.response(for: request, status: 200)
            )
        }
        let coordinator = makeCoordinator(settings: settings, transport: transport)
        let engine = try #require(coordinator.makeExternalEngine(for: .openai))

        let run = Task { try await engine.translate(["こんにちは"]) }
        let started = await pollUntil(timeout: 5) {
            gate.withLock { stored in stored != nil }
        }
        #expect(started, "the compatible retry reached the transport")
        guard started else { return }

        settings.setModel("gpt-6-sol", for: .openai)
        gate.withLock { stored in
            stored?.resume()
            stored = nil
        }

        #expect(try await run.value == ["hello"])
        #expect(
            settings.compatibleModes[.openai] == nil,
            "the old engine cannot cache a model that is no longer effective"
        )
    }

    private func makeSettings() -> TranslationSettings {
        let defaults = UserDefaults(
            suiteName: "test.CoordinatorCache.\(UUID().uuidString)"
        )!
        let settings = TranslationSettings(
            defaults: defaults, keys: InMemoryKeyStore()
        )
        try? settings.saveKey("sk-openai-1234", for: .openai)
        settings.select(.openai)
        return settings
    }

    private func makeCoordinator(
        settings: TranslationSettings, transport: HTTPTranslationTransport
    ) -> TranslationSessionCoordinator {
        TranslationSessionCoordinator(
            queue: TranslationQueue(),
            settings: settings,
            transport: transport,
            tierAvailability: AppleTierAvailability(check: { _ in false })
        )
    }

    private nonisolated static func response(
        for request: URLRequest, status: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
    }
}
