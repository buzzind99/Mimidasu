import Foundation
@testable import Mimidasu
import Testing

/// One story for both lookup paths: the same failure reaches the user as one
/// string from the single copy authority (`DictionaryError.errorDescription`),
/// and the same bare miss reads as a miss — never a failure — on the row path
/// and the tap path alike.
@Suite("Lookup cross-path consistency")
@MainActor
struct LookupCrossPathConsistencyTests {

    /// A failure the dictionary surface never typed: both paths must reach it
    /// through the same total map, so neither can invent its own copy.
    private struct Underlying: LocalizedError {
        var errorDescription: String? {
            "cross-path trouble"
        }
    }

    private let word = FavoriteWord(
        headword: "見る", reading: "みる", romaji: "miru", addedAt: 0
    )

    @MainActor
    private final class FeedbackSpy: TapLookupFeedbackSink {
        private(set) var warnings: [String] = []
        private(set) var faults: [DictionaryError] = []

        func tapLookupDidWarnNoHit(surface: String) {
            warnings.append(surface)
        }

        func tapLookupDidFail(_ fault: DictionaryError) {
            faults.append(fault)
        }
    }

    /// A resolver that always lands one fixed answer, so the session's
    /// feedback routing runs without a database.
    private struct StubResolver: TapLookupResolving {
        let answer: LookupAnswer?

        func resolve(
            _ request: TapLookupRequest, favorites: FavoriteIdentity
        ) async -> LookupAnswer? {
            answer
        }
    }

    private func request(_ surface: String) -> TapLookupRequest {
        TapLookupRequest(
            segments: [LookupSegment(surface: surface)],
            tappedAt: 0,
            sentenceText: surface,
            surface: surface
        )
    }

    /// The row's `.failed` payload, or nil when the phase is anything else.
    private func failedText(_ phase: FavoritesLookupState.Phase) -> String? {
        guard case let .failed(text) = phase else { return nil }
        return text
    }

    @Test("a failure surfaces as one string from the single copy authority on both paths")
    func oneCopyAuthority() async throws {
        let underlying = Underlying()
        let typed = DictionaryError(underlying)
        let authority = try #require(typed.errorDescription)

        // Row path: the throwing seam lands the phase on the authority's text.
        let row = FavoritesLookupState(lookupRow: { _ in throw underlying })
        row.toggle(word)
        #expect(await pollUntil(timeout: 5) { row.phase(for: word) != .loading })
        let rowText = try #require(failedText(row.phase(for: word)))
        #expect(rowText == authority)

        // Tap path: the stub resolver lands the typed failure; the sink
        // receives exactly that error, and its copy matches the row's.
        let spy = FeedbackSpy()
        let session = TapLookupSession(
            resolver: StubResolver(answer: .failure(typed))
        )
        session.feedback = spy
        await session.tap(request("見る"), anchor: .liveStrip, favorites: .empty).value

        #expect(spy.faults == [typed])
        let tapText = try #require(spy.faults.first?.errorDescription)
        #expect(tapText == authority)
        #expect(tapText == rowText)
        #expect(spy.warnings.isEmpty, "a failure never warns")
    }

    @Test("a bare miss warns on the tap and reads not-found on the row, never failing")
    func oneBareMissClassifier() async {
        // Row path: a nil landing is a miss, not a failure.
        let row = FavoritesLookupState(lookupRow: { _ in nil })
        row.toggle(word)
        #expect(await pollUntil(timeout: 5) { row.phase(for: word) != .loading })
        #expect(row.phase(for: word) == .notFound)
        #expect(failedText(row.phase(for: word)) == nil, "a miss never fails the row")

        // Tap path: the empty answer warns and never faults.
        let spy = FeedbackSpy()
        let session = TapLookupSession(
            resolver: StubResolver(answer: .noHit(surface: "見る"))
        )
        session.feedback = spy
        await session.tap(request("見る"), anchor: .liveStrip, favorites: .empty).value

        #expect(spy.warnings == ["見る"])
        #expect(spy.faults.isEmpty, "a miss never faults the tap")
    }
}
