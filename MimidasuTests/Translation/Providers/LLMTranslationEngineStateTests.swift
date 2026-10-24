import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// Covers the engine's compatible-mode memory: the one-time persistence hook
/// and the terminal-configuration shortcut.
@Suite("LLMTranslationEngine state")
struct LLMTranslationEngineStateTests {
    @Test("a successful downgrade is reported to the owner once")
    func downgradeReportedOnce() async throws {
        let client = ScriptedClient { _ in
            LLMReply(text: "hola", usedCompatibleMode: true)
        }
        let reports = Mutex(0)
        let engine = LLMTranslationEngine(
            target: .english,
            client: client,
            onCompatibleModeLearned: {
                reports.withLock { count in count += 1 }
            }
        )

        let results = try await engine.translate(["a", "b"])

        #expect(results == ["hola", "hola"])
        #expect(reports.withLock { count in count } == 1)
        #expect(engine.usedCompatibleMode)
        #expect(client.modes == [false, true])
    }

    @Test("a terminal configuration rejection sends only the field-free shape after it")
    func terminalConfigurationRejectionSticks() async throws {
        let client = ScriptedClient { compatibleMode in
            guard compatibleMode else {
                throw TranslationEngineError.invalidConfiguration("bad model")
            }
            return LLMReply(text: "hola", usedCompatibleMode: false)
        }
        let engine = LLMTranslationEngine(target: .english, client: client)

        await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["a"])
        }
        let results = try await engine.translate(["b"])

        #expect(results == ["hola"])
        #expect(client.modes == [false, true])
        #expect(!engine.usedCompatibleMode)
    }

    @Test("a seeded compatible mode never re-reports to the owner")
    func seededCompatibleModeNeverReReports() async throws {
        let client = ScriptedClient { compatibleMode in
            LLMReply(text: "hola", usedCompatibleMode: compatibleMode)
        }
        let reports = Mutex(0)
        let engine = LLMTranslationEngine(
            target: .english,
            client: client,
            compatibleMode: true,
            onCompatibleModeLearned: {
                reports.withLock { count in count += 1 }
            }
        )

        let results = try await engine.translate(["a"])

        #expect(results == ["hola"])
        #expect(client.modes == [true])
        #expect(engine.usedCompatibleMode)
        #expect(
            reports.withLock { count in count } == 0,
            "a seeded downgrade is not a new discovery"
        )
    }

    @Test("a terminal configuration latch never fires the persistence hook")
    func terminalLatchNeverReports() async throws {
        let client = ScriptedClient { compatibleMode in
            guard compatibleMode else {
                throw TranslationEngineError.invalidConfiguration("bad model")
            }
            return LLMReply(text: "hola", usedCompatibleMode: false)
        }
        let reports = Mutex(0)
        let engine = LLMTranslationEngine(
            target: .english,
            client: client,
            onCompatibleModeLearned: {
                reports.withLock { count in count += 1 }
            }
        )

        await #expect(throws: TranslationEngineError.self) {
            try await engine.translate(["a"])
        }
        let results = try await engine.translate(["b"])

        #expect(results == ["hola"])
        #expect(
            reports.withLock { count in count } == 0,
            "the terminal latch is not a learned downgrade"
        )
    }
}

/// A chat client whose replies and observed compatible-mode flags are
/// scripted, with no transport involved.
private final class ScriptedClient: LLMChatClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedModes: [Bool] = []
    private let respond: @Sendable (Bool) throws -> LLMReply

    init(respond: @escaping @Sendable (Bool) throws -> LLMReply) {
        self.respond = respond
    }

    var modes: [Bool] {
        lock.withLock { recordedModes }
    }

    func complete(
        _ messages: [LLMChatMessage],
        compatibleMode: Bool,
        onRetry: (@Sendable (RetryProgress) -> Void)?
    ) async throws -> LLMReply {
        lock.withLock { recordedModes.append(compatibleMode) }
        return try respond(compatibleMode)
    }
}
