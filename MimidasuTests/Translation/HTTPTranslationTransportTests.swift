import Foundation
@testable import Mimidasu
import Testing

/// Tests `HTTPTranslationTransport` through the injectable `perform`
/// closure — no network, fully parallel-safe.
@Suite("HTTPTranslationTransport")
struct HTTPTranslationTransportTests {

    // MARK: - Helpers

    /// `nonisolated(unsafe)`: capture-free factory returning a fresh
    /// response per call — no shared mutable state.
    private nonisolated(unsafe) static let okResponse = {
        HTTPURLResponse(url: URL(string: "https://provider.test/translate")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private func makeTransport(
        response: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    ) -> HTTPTranslationTransport {
        HTTPTranslationTransport(timeout: 1, perform: response)
    }

    private static func response(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://provider.test/translate")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    // MARK: - HTTPS enforcement

    @Test("plain-HTTP requests are rejected as network errors")
    func plainHTTPRejected() async throws {
        let transport = makeTransport { _ in (Data(), Self.okResponse()) }
        var request = try URLRequest(url: #require(URL(string: "http://provider.test/translate")))
        request.httpMethod = "POST"

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await transport.send(request) { _, _ in nil }
        }

        #expect(thrown == .network)
    }

    // MARK: - Success path

    @Test("a 2xx response returns the body")
    func successReturnsBody() async throws {
        let body = Data(#"{"ok":true}"#.utf8)
        let transport = makeTransport { _ in (body, Self.okResponse()) }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        let returned = try await transport.send(request) { _, _ in nil }

        #expect(returned == body)
    }

    // MARK: - Error classification

    @Test(
        "non-2xx responses surface the provider's classification with Retry-After",
        arguments: [
            ("30", TimeInterval(10)),
            ("2", TimeInterval(2)),
            ("soon", TimeInterval?.none)
        ]
    )
    func non2xxClassifiedWithRetryAfter(
        header: String, expectedRetryAfter: TimeInterval?
    ) async throws {
        let transport = makeTransport { _ in (Data(), Self.response(429, headers: ["Retry-After": header])) }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        let thrown = await #expect(throws: HTTPTranslationTransport.Failure.self) {
            try await transport.send(request) { _, _ in .rateLimited }
        }

        let failure = try #require(thrown)
        #expect(failure.engineError == .rateLimited)
        #expect(failure.retryAfter == expectedRetryAfter)
    }

    // MARK: - Transport-level failures

    @Test(
        "transport-level URL errors map to network",
        arguments: [URLError.Code.notConnectedToInternet, .timedOut]
    )
    func urlErrorMapsToNetwork(code: URLError.Code) async throws {
        let transport = makeTransport { _ in
            throw URLError(code)
        }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        let thrown = await #expect(throws: TranslationEngineError.self) {
            try await transport.send(request) { _, _ in nil }
        }

        #expect(thrown == .network)
    }

    @Test("request cancellation stays CancellationError")
    func cancellationStaysCancellation() async throws {
        let transport = makeTransport { _ in
            throw URLError(.cancelled)
        }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        await #expect(throws: CancellationError.self) {
            try await transport.send(request) { _, _ in nil }
        }
    }

    @Test("a thrown CancellationError passes through unchanged")
    func thrownCancellationErrorPassesThrough() async throws {
        let transport = makeTransport { _ in
            throw CancellationError()
        }
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        await #expect(throws: CancellationError.self) {
            try await transport.send(request) { _, _ in nil }
        }
    }
}

/// Drives the production `perform` closure (a real `URLSession`) with a
/// stubbed `URLProtocol` injected through the configuration — no network.
@Suite("HTTPTranslationTransport default session")
struct HTTPTranslationTransportSessionTests {

    /// Returns a 200 with a fixed body for every request, without a network.
    private class StubURLProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test("the default transport performs a real URLSession round-trip")
    func defaultTransportRoundTripReturns2xxBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let transport = HTTPTranslationTransport(timeout: 1, configuration: configuration)
        let request = try URLRequest(url: #require(URL(string: "https://provider.test/translate")))

        let returned = try await transport.send(request) { _, _ in nil }

        #expect(returned == Data(#"{"ok":true}"#.utf8))
    }
}
