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
        let model = makeIdleModel(
            suite: "test.AppModelTarget",
            translationSettings: settings,
            translationTransport: constantStatusTransport(500)
        )

        model.retryTranslation()
        #expect(await pollUntil { model.translationRuntime.status == .ready })
        #expect(model.translationQueue.targetLangCode == "zh-Hans", "attach stamps the queue")

        // Re-engage the Apple host: its config must carry the same target.
        model.phase = .running
        settings.select(.apple)
        model.translationProviderDidChange()
        #expect(model.translationRuntime.engine == .apple)
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
        let model = makeIdleModel(suite: "test.AppModelTarget")

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
    /// request body's system prompt names the selected language, and every
    /// LLM provider shares the same prompt contract (including the ASR
    /// caveat) with its own default model.
    @Test(
        "the selected target reaches the attached engine's prompt",
        arguments: [
            (
                provider: TranslationProvider.openrouter,
                target: TargetLanguage(code: "zh-Hans"),
                languageName: "Simplified Chinese",
                model: "tencent/hy-mt2-30b-a3b"
            ),
            (
                provider: .openai,
                target: TargetLanguage(code: "es"),
                languageName: "Spanish",
                model: "gpt-6-luna"
            )
        ]
    )
    func selectedTargetReachesEnginePrompt(
        provider: TranslationProvider, target: TargetLanguage,
        languageName: String, model expectedModel: String
    ) async throws {
        let settings = makeSettings(provider: provider, target: target)
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
        let model = makeIdleModel(
            suite: "test.AppModelTarget", translationSettings: settings, translationTransport: transport
        )

        model.retryTranslation()
        model.translationQueue.enqueue(makeSentence(index: 0, text: "テスト"))
        #expect(await pollUntil(timeout: resultTimeout) { !bodies.bodies.isEmpty })

        let body = try #require(bodies.bodies.first)
        let decoded = try JSONDecoder().decode(ChatBody.self, from: body)
        #expect(decoded.model == expectedModel)
        #expect(decoded.messages[0].role == "system")
        #expect(decoded.messages[0].content.contains(languageName))
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
