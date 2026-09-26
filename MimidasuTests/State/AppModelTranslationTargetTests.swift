import Foundation
@testable import Mimidasu
import Synchronization
import Testing
@preconcurrency import Translation

/// Tests `AppModel`'s target-language wiring (restart-only): the selected
/// target stamps the queue at engine attach, carries into the rebuilt Apple
/// config, and reaches the attached OpenRouter engine's system prompt.
@MainActor
@Suite("AppModel target language")
struct AppModelTranslationTargetTests {

    // MARK: - Fixtures

    private let resultTimeout: TimeInterval = 5

    private func makeSentence(index: Int, text: String) -> Sentence {
        Sentence(index: index, startS: 0, endS: 1, lang: "ja", text: text)
    }

    private func makeSettings() -> TranslationSettings {
        let settings = isolatedTranslationSettings(suite: "test.AppModelTarget")
        try? settings.saveKey("test-key-1234", for: .openrouter)
        settings.select(.openrouter)
        settings.select(TargetLanguage(code: "zh-Hans"))
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
            translationTransport: constantStatusTransport(500),
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

    // MARK: - External engine wiring

    /// The engine built by `makeExternalEngine` receives the target: the
    /// OpenRouter request body's system prompt names the selected language.
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
            translationTransport: transport,
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

    let messages: [Message]
}
