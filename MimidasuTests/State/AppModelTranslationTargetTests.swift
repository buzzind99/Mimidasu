import Foundation
@testable import Mimidasu
import Synchronization
import Testing
@preconcurrency import Translation

/// Tests `AppModel`'s target-language wiring (restart-only): the selected
/// target stamps the queue at engine attach, carries into the rebuilt Apple
/// config, and reaches the attached LLM engine's system prompt.
@MainActor
@Suite("AppModel target language")
struct AppModelTranslationTargetTests {

    // MARK: - Fixtures

    private let resultTimeout: TimeInterval = 5

    private func makeSentence(index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    private func makeSettings(
        provider: TranslationProvider = .openrouter,
        target: TargetLanguage = TargetLanguage(code: "zh-Hans")
    ) -> TranslationSettings {
        let settings = isolatedTranslationSettings(suite: "test.AppModelTarget")
        try? settings.saveKey("test-key-1234", for: provider)
        settings.select(provider)
        settings.select(target)
        return settings
    }

    /// Tears the model's translation worker down (stop requires a session
    /// phase; the queue worker is what actually needs cancelling).
    private func stopTranslation(_ model: AppModel) async {
        model.phase = .running
        model.stop()
        #expect(await pollUntil(timeout: 5) { model.phase == .idle }, "stop() winds the phase down to idle")
    }

    // MARK: - Queue + Apple config

    /// The selected target stamps the queue at engine attach and shows up
    /// in the rebuilt Apple config after a mid-session provider change
    /// re-engages the on-device host.
    @Test("the selected target stamps the queue and the Apple config")
    func selectedTargetStampsQueueAndConfig() async {
        let settings = makeSettings()
        let model = AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelTarget"),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            translationTransport: constantStatusTransport(500),
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        #expect(await pollUntil { model.translationStatus == .ready })
        #expect(model.translationQueue.targetLangCode == "zh-Hans", "attach stamps the queue")

        // Re-engage the Apple host: its config must carry the same target.
        model.phase = .running
        settings.select(.apple)
        model.translationProviderDidChange()
        #expect(model.activeTranslationEngine == .apple)
        #expect(
            model.translationConfig?.target == Locale.Language(identifier: "zh-Hans"),
            "the Apple config targets the selected language"
        )
        #expect(
            model.translationConfig?.source == Locale.Language(identifier: "ja"),
            "the source stays fixed to Japanese"
        )

        await stopTranslation(model)
    }

    // MARK: - Strategy

    /// The Apple config prefers the high-fidelity (Apple Intelligence)
    /// strategy on macOS 26.4+; earlier systems can't express it, so the
    /// suite cancels visibly instead of passing silently.
    @Test("the Apple config prefers the high-fidelity strategy when available")
    func appleConfigPrefersHighFidelityWhenAvailable() async throws {
        guard #available(macOS 26.4, *) else {
            try Test.cancel("preferredStrategy requires macOS 26.4")
        }
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.AppModelTarget"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelTarget"),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        #expect(model.translationConfig != nil, "the Apple path builds the config synchronously")
        #expect(
            model.translationConfig?.preferredStrategy == .highFidelity,
            "the config prefers the high-fidelity strategy"
        )

        // Quiesce the launch-time model check before stopping: its async
        // landing would otherwise clobber the stop-wound phase and the
        // teardown poll would never observe `.idle`.
        await model.initialModelCheck?.value

        await stopTranslation(model)
    }

    // MARK: - External engine wiring

    /// The engine built by `makeExternalEngine` receives the target: the
    /// request body's system prompt names the selected language.
    @Test("the selected target reaches the attached engine's prompt")
    func selectedTargetReachesEnginePrompt() async throws {
        let settings = makeSettings()
        let bodies = BodyLog()
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            bodies.record(request.httpBody ?? Data())
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        let model = AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelTarget"),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            translationTransport: transport,
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))
        #expect(await pollUntil(timeout: resultTimeout) { !bodies.bodies.isEmpty })

        let body = try #require(bodies.bodies.first)
        let decoded = try JSONDecoder().decode(ChatBody.self, from: body)
        #expect(decoded.messages[0].role == "system")
        #expect(decoded.messages[0].content.contains("Simplified Chinese"))

        await stopTranslation(model)
    }

    /// Every LLM provider shares one prompt contract, so a non-default
    /// provider's request must also name the selected target and keep the ASR
    /// caveat.
    @Test("an LLM provider's prompt names the selected target and keeps the ASR caveat")
    func openAIPromptNamesSpanishTarget() async throws {
        let settings = makeSettings(
            provider: .openai,
            target: TargetLanguage(code: "es")
        )
        let bodies = BodyLog()
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            bodies.record(request.httpBody ?? Data())
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (
                Data(#"{"choices":[{"message":{"content":"hola"}}]}"#.utf8),
                response
            )
        }
        let model = AppModel(
            translationSettings: settings,
            asrModelSettings: isolatedASRModelSettings(suite: "test.AppModelTarget"),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            translationTransport: transport,
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )

        model.retryTranslation()
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))
        #expect(await pollUntil(timeout: resultTimeout) { !bodies.bodies.isEmpty })

        let body = try #require(bodies.bodies.first)
        let decoded = try JSONDecoder().decode(ChatBody.self, from: body)
        #expect(decoded.model == "gpt-6-luna")
        #expect(decoded.messages[0].role == "system")
        #expect(decoded.messages[0].content.contains("Spanish"))
        #expect(decoded.messages[0].content.contains("ASR output"))

        await stopTranslation(model)
    }

    /// Transport that always answers with the given HTTP status (a failing
    /// engine without retry-inducing latency).
    private func constantStatusTransport(_ status: Int) -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 5) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
    }

    /// Thread-safe request-body log (transports run off the main actor).
    private final class BodyLog: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [Data] = []

        func record(_ body: Data) {
            lock.withLock { log.append(body) }
        }

        var bodies: [Data] {
            lock.withLock { log }
        }
    }
}

/// Minimal chat-completions request shape for prompt assertions.
private struct ChatBody: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
}
