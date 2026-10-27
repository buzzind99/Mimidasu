import Foundation
@testable import Mimidasu
import Testing

/// The Lookup Display module's failure map, driven over the fixture database:
/// the infrastructure failures — missing, closed, corrupt — plus
/// the empty-segments and empty-surface gates land on their typed failures;
/// nil segments answer a no-hit instead.
/// A generic internal error stays covered at the pure map in
/// `DictionaryErrorTests`: the engine is concrete, so no throwing stub seam
/// exists for it here and none is introduced.
@Suite("LookupDisplay faults")
final class LookupDisplayFaultTests {
    private let harness: LookupDisplayHarness

    init() throws {
        harness = try LookupDisplayHarness()
    }

    @Test("nil segments warn with the tapped surface")
    func nilSegmentsWarn() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: nil, tappedAt: 0, sentenceText: "", surface: "お"
        )

        let answer = await display.resolve(request, favorites: .empty)

        #expect(answer == .noHit(surface: "お"))
    }

    @Test("nil segments with an empty surface fault as annotator-unavailable")
    func nilSegmentsEmptySurfaceFaults() async {
        let request = TapLookupRequest(segments: nil, tappedAt: 0, sentenceText: "", surface: "")
        let answer = await harness.makeDisplay().resolve(request, favorites: .empty)
        #expect(answer == .failure(.annotatorUnavailable))
    }

    @Test("empty segments fault as annotator-unavailable")
    func emptySegmentsFault() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [], tappedAt: 0, sentenceText: "お土産", surface: "お"
        )

        let answer = await display.resolve(request, favorites: .empty)

        #expect(answer == .failure(.annotatorUnavailable))
    }

    @Test("an empty surface faults even when segments are present")
    func emptySurfaceWithSegmentsFaults() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [LookupSegment(surface: "あめ")], tappedAt: 0,
            sentenceText: "あめ", surface: ""
        )

        let answer = await display.resolve(request, favorites: .empty)

        #expect(answer == .failure(.annotatorUnavailable))
    }

    @Test("a missing database faults as database-missing")
    func missingDatabaseFaults() async {
        let display = harness.makeDisplay(resolveDatabase: { nil })

        let answer = await display.resolve(harness.requestO(), favorites: .empty)

        #expect(answer == .failure(.databaseMissing))
    }

    @Test("a closed engine faults as database-closed")
    func closedDatabaseFaults() async {
        let url = harness.fixture.url
        let engine = JMDictLookup(resolveDatabase: { [url] in url })
        engine.close()
        let display = LookupDisplay(lookup: engine)

        let answer = await display.resolve(harness.requestO(), favorites: .empty)

        #expect(answer == .failure(.databaseClosed))
    }

    @Test("a warmed engine faults as database-closed after close")
    func warmedCloseFaultsClosed() async {
        let url = harness.fixture.url
        let engine = JMDictLookup(resolveDatabase: { [url] in url })
        let display = LookupDisplay(lookup: engine)
        let first = await display.resolve(harness.requestO(), favorites: .empty)
        guard requirePinnable(first) != nil else {
            Issue.record("expected a pinnable answer, got \(String(describing: first))")
            return
        }
        engine.close()

        let answer = await display.resolve(harness.requestO(), favorites: .empty)

        #expect(answer == .failure(.databaseClosed))
    }

    @Test("a corrupt database faults as a sqlite error")
    func corruptDatabaseFaults() async throws {
        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-corrupt-\(UUID().uuidString).sqlite")
        try "not a database".write(to: garbage, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: garbage) }
        let display = harness.makeDisplay(resolveDatabase: { [garbage] in garbage })

        let answer = await display.resolve(harness.requestO(), favorites: .empty)

        guard case let .failure(error) = answer else {
            Issue.record("expected a failure, got \(String(describing: answer))")
            return
        }
        guard case let .sqliteError(code, message) = error else {
            Issue.record("expected sqlite error, got \(error)")
            return
        }
        #expect(code != 0)
        #expect(!message.isEmpty)
    }

    /// Built over the shared orphan-headword fixture, which carries just the
    /// three-table shape this path needs.
    @Test("an orphan headword row faults as database-corrupt")
    func orphanHeadwordRowFaultsCorrupt() async throws {
        let built = try JMDictFixtureDatabase.orphanHeadword()
        let url = built.url
        let engine = JMDictLookup(resolveDatabase: { [url] in url })
        defer {
            engine.close()
            built.remove()
        }
        let display = LookupDisplay(lookup: engine)
        let request = TapLookupRequest(
            segments: [LookupSegment(surface: "孤語")],
            tappedAt: 0,
            sentenceText: "孤語",
            surface: "孤語"
        )

        let answer = await display.resolve(request, favorites: .empty)

        #expect(answer == .failure(.databaseCorrupt))
    }
}
