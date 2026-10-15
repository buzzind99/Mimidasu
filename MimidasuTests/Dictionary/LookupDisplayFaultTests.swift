import Foundation
@testable import Mimidasu
import Testing

/// The Lookup Display module's fault map, driven over the fixture database:
/// every infrastructure failure — missing, dangling, closed, corrupt — plus
/// the nil/empty segments and empty-surface gates, lands on its typed fault.
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

        let effect = await display.resolve(request, favorites: [])

        #expect(effect == .warnNoHit(surface: "お"))
    }

    @Test("nil segments with an empty surface fault as annotator-unavailable")
    func nilSegmentsEmptySurfaceFaults() async {
        let request = TapLookupRequest(segments: nil, tappedAt: 0, sentenceText: "", surface: "")
        let effect = await harness.makeDisplay().resolve(request, favorites: [])
        #expect(effect == .fault(.annotatorUnavailable))
    }

    @Test("empty segments fault as annotator-unavailable")
    func emptySegmentsFault() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [], tappedAt: 0, sentenceText: "お土産", surface: "お"
        )

        let effect = await display.resolve(request, favorites: [])

        #expect(effect == .fault(.annotatorUnavailable))
    }

    @Test("an empty surface faults even when segments are present")
    func emptySurfaceWithSegmentsFaults() async {
        let display = harness.makeDisplay()
        let request = TapLookupRequest(
            segments: [LookupSegment(surface: "あめ")], tappedAt: 0,
            sentenceText: "あめ", surface: ""
        )

        let effect = await display.resolve(request, favorites: [])

        #expect(effect == .fault(.annotatorUnavailable))
    }

    @Test("a missing database faults as database-missing")
    func missingDatabaseFaults() async {
        let display = harness.makeDisplay(resolveDatabase: { nil })

        let effect = await display.resolve(harness.requestO(), favorites: [])

        #expect(effect == .fault(.databaseMissing))
    }

    @Test("a closed engine faults as database-closed")
    func closedDatabaseFaults() async {
        let url = harness.fixture.url
        let engine = JMDictLookup(resolveDatabase: { [url] in url })
        engine.close()
        let display = LookupDisplay(lookup: engine)

        let effect = await display.resolve(harness.requestO(), favorites: [])

        #expect(effect == .fault(.databaseClosed))
    }

    @Test("a warmed engine faults as database-closed after close")
    func warmedCloseFaultsClosed() async {
        let url = harness.fixture.url
        let engine = JMDictLookup(resolveDatabase: { [url] in url })
        let display = LookupDisplay(lookup: engine)
        let first = await display.resolve(harness.requestO(), favorites: [])
        guard case .show = first else {
            Issue.record("expected show, got \(first)")
            return
        }
        engine.close()

        let effect = await display.resolve(harness.requestO(), favorites: [])

        #expect(effect == .fault(.databaseClosed))
    }

    @Test("a dangling database URL faults as database-missing")
    func danglingDatabaseURLFaultsMissing() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-missing-\(UUID().uuidString).sqlite")
        let display = harness.makeDisplay(resolveDatabase: { [missing] in missing })

        let effect = await display.resolve(harness.requestO(), favorites: [])

        #expect(effect == .fault(.databaseMissing))
    }

    @Test("a corrupt database faults as a sqlite error")
    func corruptDatabaseFaults() async throws {
        let garbage = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimidasu-corrupt-\(UUID().uuidString).sqlite")
        try "not a database".write(to: garbage, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: garbage) }
        let display = harness.makeDisplay(resolveDatabase: { [garbage] in garbage })

        let effect = await display.resolve(harness.requestO(), favorites: [])

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
}
