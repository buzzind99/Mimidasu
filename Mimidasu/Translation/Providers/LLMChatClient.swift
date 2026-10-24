import Foundation

/// One chat message on the provider-independent LLM seam.
struct LLMChatMessage: Codable, Sendable, Equatable {
    let role: String
    let content: String
}

/// A translated reply plus whether the request had to drop its fast-mode
/// fields for this provider+model (the compatible fallback).
struct LLMReply: Sendable, Equatable {
    let text: String
    let usedCompatibleMode: Bool
}

/// The seam the generic LLM engine sees: a client transports messages,
/// applies the provider's response decoding, and returns the parsed reply.
/// Parsing runs inside the client's retry ladder so malformed LLM output
/// consumes the transient budget like any other bad response.
protocol LLMChatClient: Sendable {
    func complete(
        _ messages: [LLMChatMessage],
        compatibleMode: Bool,
        onRetry: (@Sendable (RetryProgress) -> Void)?
    ) async throws -> LLMReply
}
