import Foundation
@testable import Mimidasu
import Testing

/// Tests `TranslationConnectionTester` against scripted transports. Every
/// probe captures the request it issues, so both the request shape and the
/// zero-retry ladder wiring are asserted, not just the outcome.
@Suite("TranslationConnectionTester")
struct TranslationConnectionTesterTests {

    // MARK: - Helpers

    private static func httpResponse(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    /// Records every request the probe issues; responses come from a scripted
    /// per-call handler, so retries (or the lack of them) are observable.
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        private(set) var bodies: [Data] = []

        let handler: @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse)

        init(handler: @escaping @Sendable (_ index: Int) throws -> (Data, HTTPURLResponse)) {
            self.handler = handler
        }

        func record(_ request: URLRequest) {
            lock.withLock {
                requests.append(request)
                bodies.append(request.httpBody ?? Data())
            }
        }

        var requestCount: Int {
            lock.withLock { requests.count }
        }
    }

    private func makeTransport(_ script: Script) -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 1) { request in
            let index = script.requestCount
            script.record(request)
            return try script.handler(index)
        }
    }

    // MARK: - Probes

    @Test("Apple needs no probe")
    func appleSucceeds() async throws {
        try await TranslationConnectionTester.test(provider: .apple, key: "")
    }

    @Test("Google probes with a one-sentence translate")
    func googleProbe() async throws {
        let script = Script(handler: { _ in
            (
                Data(#"{"data":{"translations":[{"translatedText":"hello"}]}}"#.utf8),
                Self.httpResponse(GoogleTranslateEngine.endpoint, 200)
            )
        })
        let transport = makeTransport(script)

        try await TranslationConnectionTester.test(provider: .google, key: "k", transport: transport)

        let request = try #require(script.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == GoogleTranslateEngine.endpoint)
        #expect(request.value(forHTTPHeaderField: "X-goog-api-key") == "k")
        let decoded = try JSONDecoder().decode(GoogleProbeBody.self, from: #require(script.bodies.first))
        #expect(decoded.q == ["こんにちは"])
    }

    @Test("DeepL probes with a one-sentence translate against the Pro endpoint")
    func deeplProbe() async throws {
        let script = Script(handler: { _ in
            (
                Data(#"{"translations":[{"detected_source_language":"JA","text":"hello"}]}"#.utf8),
                Self.httpResponse(DeepLEngine.proEndpoint, 200)
            )
        })
        let transport = makeTransport(script)

        try await TranslationConnectionTester.test(provider: .deepl, key: "k", transport: transport)

        let request = try #require(script.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == DeepLEngine.proEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key k")
        let decoded = try JSONDecoder().decode(DeepLProbeBody.self, from: #require(script.bodies.first))
        #expect(decoded.text == ["こんにちは"])
        #expect(decoded.sourceLang == "JA")
        #expect(decoded.targetLang == "EN")
    }

    @Test("OpenRouter probes GET /api/v1/key with the bearer key")
    func openRouterKeyProbe() async throws {
        let keyURL = try #require(URL(string: "https://openrouter.ai/api/v1/key"))
        let script = Script(handler: { _ in (Data(), Self.httpResponse(keyURL, 200)) })
        let transport = makeTransport(script)

        try await TranslationConnectionTester.test(provider: .openrouter, key: "or-key", transport: transport)

        let request = try #require(script.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url == keyURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer or-key")
    }

    // MARK: - Failures

    @Test("an invalid Google key fails with invalidKey")
    func googleInvalidKey() async {
        let script = Script(handler: { _ in (Data(), Self.httpResponse(GoogleTranslateEngine.endpoint, 403)) })
        let transport = makeTransport(script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await TranslationConnectionTester.test(provider: .google, key: "k", transport: transport)
        }

        #expect(thrown == .invalidKey)
        #expect(script.requestCount == 1)
    }

    @Test("an invalid DeepL key fails with invalidKey without retrying")
    func deeplInvalidKey() async {
        let script = Script(handler: { _ in (Data(), Self.httpResponse(DeepLEngine.proEndpoint, 403)) })
        let transport = makeTransport(script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await TranslationConnectionTester.test(provider: .deepl, key: "k", transport: transport)
        }

        #expect(thrown == .invalidKey)
        #expect(script.requestCount == 1)
    }

    /// A transient failure is *not* retried: the probe ladder runs with zero
    /// retries so a failed Test settles in a single round-trip.
    @Test("a transient probe failure is not retried")
    func transientProbeFailureIsNotRetried() async {
        let script = Script(handler: { _ in (Data(), Self.httpResponse(DeepLEngine.proEndpoint, 429)) })
        let transport = makeTransport(script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await TranslationConnectionTester.test(provider: .deepl, key: "k", transport: transport)
        }

        #expect(thrown == .rateLimited)
        #expect(script.requestCount == 1, "the probe ladder has zero retries")
    }

    @Test("a DeepL probe with an empty translation fails as badResponse")
    func deeplEmptyTranslation() async {
        let script = Script(handler: { _ in
            (Data(#"{"translations":[{"text":""}]}"#.utf8), Self.httpResponse(DeepLEngine.proEndpoint, 200))
        })
        let transport = makeTransport(script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await TranslationConnectionTester.test(provider: .deepl, key: "k", transport: transport)
        }

        #expect(thrown == .badResponse("Provider returned an empty translation"))
    }

    @Test("an invalid OpenRouter key fails with invalidKey")
    func openRouterInvalidKey() async throws {
        let keyURL = try #require(URL(string: "https://openrouter.ai/api/v1/key"))
        let script = Script(handler: { _ in (Data(), Self.httpResponse(keyURL, 401)) })
        let transport = makeTransport(script)

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await TranslationConnectionTester.test(provider: .openrouter, key: "or-key", transport: transport)
        }

        #expect(thrown == .invalidKey)
    }
}

private struct GoogleProbeBody: Decodable {
    let q: [String]
}

private struct DeepLProbeBody: Decodable {
    let text: [String]
    let sourceLang: String
    let targetLang: String

    enum CodingKeys: String, CodingKey {
        case text
        case sourceLang = "source_lang"
        case targetLang = "target_lang"
    }
}
