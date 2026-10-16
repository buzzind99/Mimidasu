import Foundation
@testable import Mimidasu
import Testing

/// The Lookup Display module's fault map, driven over the fixture database:
/// the infrastructure failures — missing, dangling, closed, corrupt — plus
/// the empty-segments and empty-surface gates land on their typed faults;
/// nil segments warn instead.
/// A generic internal error stays covered at the pure map in
/// `TapLookupFaultTests`: the engine is concrete, so no throwing stub seam
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

        let effect = await display.resolve(request, favorites: .empty)

        #expect(effect == .warnNoHit(surface: "お"))
    }

    @Test("nil segments with an empty surface fault as annotator-unavailable")
    func nilSegmentsEmptySurfaceFaults() async {
        let request = TapLookupRequest(segments: nil, tappedAt: 0, sentenceText: "", surface: "")
        let effect = await harness.makeDisplay().resolve(request, favorites: .empty)
        #expect(effect == .fault(.annotatorUnavailable))
    }

    @Test("empty segments fault as annotator-unavailable")
    func emptySegmentsFault() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [], tappedAt: 0, sentenceText: "お土産", surface: "お"
        )

        let effect = await display.resolve(request, favorites: .empty)

        #expect(effect == .fault(.annotatorUnavailable))
    }

    @Test("an empty surface faults even when segments are present")
    func emptySurfaceWithSegmentsFaults() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [LookupSegment(surface: "あめ")], tappedAt: 0,
            sentenceText: "あめ", surface: ""
        )

        let effect = await display.resolve(request, favorites: .empty)

        #expect(effect == .fault(.annotatorUnavailable))
    }

    @Test("a missing database faults as database-missing")
    func missingDatabaseFaults() async {
        let display = harness.makeDisplay(resolveDatabase: { nil })

        let effect = await display.resolve(harness.requestO(), favorites: .empty)

        #expect(effect == .fault(.databaseMissing))
    }

    @Test("a closed engine faults as database-closed")
    func closedDatabaseFaults() async {
        let url = harness.fixture.url
        let engine = JMDictLookup(resolveDatabase: { [url] in url })
        engine.close()
        let display = LookupDisplay(lookup: engine)

        let effect = await display.resolve(harness.requestO(), favorites: .empty)

        #expect(effect == .fault(.databaseClosed))
    }

    @Test("a warmed engine faults as database-closed after close")
    func warmedCloseFaultsClosed() async {
        let url = harness.fixture.url
        let engine = JMDictLookup(resolveDatabase: { [url] in url })
        let display = LookupDisplay(lookup: engine)
        let first = await display.resolve(harness.requestO(), favorites: .empty)
        guard case .show = first else {
            Issue.record("expected show, got \(first)")
            return
        }
        engine.close()

        let effect = await display.resolve(harness.requestO(), favorites: .empty)

        #expect(effect == .fault(.databaseClosed))
    }

    @Test("a dangling database URL faults as database-missing")
    func danglingDatabaseURLFaultsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-missing-\(UUID().uuidString).sqlite")
        let display = harness.makeDisplay(resolveDatabase: { [missing] in missing })

        let effect = await display.resolve(harness.requestO(), favorites: .empty)

        #expect(effect == .fault(.databaseMissing))
    }

    @Test("a corrupt database faults as a sqlite error")
    func corruptDatabaseFaults() async throws {
        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-corrupt-\(UUID().uuidString).sqlite")
        try "not a database".write(to: garbage, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: garbage) }
        let display = harness.makeDisplay(resolveDatabase: { [garbage] in garbage })

        let effect = await display.resolve(harness.requestO(), favorites: .empty)

        guard case let .fault(fault) = effect else {
            Issue.record("expected fault, got \(effect)")
            return
        }
        guard case let .sqliteError(code, message) = fault else {
            Issue.record("expected sqlite error, got \(fault)")
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

        let effect = await display.resolve(request, favorites: .empty)

        #expect(effect == .fault(.databaseCorrupt))
    }
}
