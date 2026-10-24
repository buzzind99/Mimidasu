import Foundation
@testable import Mimidasu
import Testing

/// Verifies the single engine-construction path routes every LLM provider to
/// its catalog endpoint, auth style, default model, and envelope type.
@Suite("TranslationEngineFactory")
struct TranslationEngineFactoryTests {
    @Test("every LLM provider compiles to its catalog client and default model")
    func llmProvidersUseCatalogDefaults() async throws {
        for provider in TranslationProvider.allCases where provider.isLLM {
            let recorder = RequestRecorder()
            let transport = HTTPTranslationTransport(timeout: 5) { request in
                recorder.record(request)
                let response = try HTTPURLResponse(
                    url: #require(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Self.replyBody(for: provider), response)
            }
            let engine = try #require(
                TranslationEngineFactory.make(
                    provider: provider,
                    key: "secret",
                    model: "  ",
                    target: .english,
                    transport: transport
                )
            )

            let results = try await engine.translate(["こんにちは"])

            #expect(results == ["hello"])
            let request = try #require(recorder.requests.first)
            let spec = try #require(LLMProviderCatalog.spec(for: provider))
            #expect(request.url == spec.endpoint)
            #expect(engine.transientBadResponse)
            Self.expectAuthHeaders(for: provider, in: request)

            let body = try #require(
                try JSONSerialization.jsonObject(
                    with: request.httpBody ?? Data()
                ) as? [String: Any]
            )
            #expect(body["model"] as? String == spec.defaultModel)
            #expect(body["messages"] is [[String: Any]])
            if provider == .anthropic {
                #expect(body["system"] is String)
                #expect(body["max_tokens"] as? Int == 4096)
            } else {
                #expect(body["max_tokens"] == nil)
            }
        }
    }

    @Test("a non-empty padded model is trimmed before it reaches the wire")
    func paddedModelTrimsBeforeTheWire() async throws {
        let recorder = RequestRecorder()
        let transport = HTTPTranslationTransport(timeout: 5) { request in
            recorder.record(request)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Self.replyBody(for: .openai), response)
        }
        let engine = try #require(
            TranslationEngineFactory.make(
                provider: .openai,
                key: "secret",
                model: "  gpt-6-sol  ",
                target: .english,
                transport: transport
            )
        )

        _ = try await engine.translate(["こんにちは"])

        let request = try #require(recorder.requests.first)
        let body = try #require(
            try JSONSerialization.jsonObject(
                with: request.httpBody ?? Data()
            ) as? [String: Any]
        )
        #expect(body["model"] as? String == "gpt-6-sol")
    }

    /// The default-ladder `true` half is pinned by
    /// `llmProvidersUseCatalogDefaults`; this pins the derivation in the
    /// other direction — a non-retrying ladder must reach the engine.
    @Test("the engine's transient-bad-response posture follows the injected ladder")
    func transientBadResponseFollowsInjectedLadder() throws {
        let engine = try #require(
            TranslationEngineFactory.make(
                provider: .openai,
                key: "secret",
                model: "",
                target: .english,
                transport: nil,
                ladder: TransientRetryLadder(retriesBadResponse: false)
            )
        )

        #expect(!engine.transientBadResponse)
    }

    private static func expectAuthHeaders(
        for provider: TranslationProvider, in request: URLRequest
    ) {
        if provider == .anthropic {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
            #expect(
                request.value(forHTTPHeaderField: "anthropic-version")
                    == "2023-06-01"
            )
        } else {
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer secret"
            )
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        }
    }

    private static func replyBody(for provider: TranslationProvider) -> Data {
        if provider == .anthropic {
            Data(#"{"content":[{"type":"text","text":"hello"}]}"#.utf8)
        } else {
            Data(#"{"choices":[{"message":{"content":"hello"}}]}"#.utf8)
        }
    }
}

/// Locked request log for the transport closure.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { storage.append(request) }
    }

    var requests: [URLRequest] {
        lock.withLock { storage }
    }
}
