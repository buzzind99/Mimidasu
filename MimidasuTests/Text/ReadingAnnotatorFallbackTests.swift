@testable import Mimidasu
import Synchronization
import Testing

/// The annotator's cached reading-fallback wrapper: real readings and
/// genuine misses cache per surface, an infrastructure throw answers nil
/// uncached (the reading-path twin of the headword gate's memo contract).
@Suite("ReadingAnnotator reading fallback wrapper")
struct ReadingAnnotatorReadingFallbackTests {

    @Test("a second call for the same surface does not re-invoke the probe (misses included)")
    func memoHits() {
        let probes = Mutex(0)
        let fallback = ReadingAnnotator.cachedReadingFallback { surface in
            probes.withLock { count in count += 1 }
            return surface == "圧" ? "あつ" : nil
        }

        #expect(fallback("圧") == "あつ")
        #expect(fallback("圧") == "あつ")
        #expect(fallback("㐂") == nil)
        #expect(fallback("㐂") == nil)
        #expect(probes.withLock { count in count } == 2)
    }

    @Test("a throw answers nil without caching, so the next call re-probes")
    func throwAnswersNilUncached() {
        let throwing = Mutex(true)
        let probes = Mutex(0)
        let fallback = ReadingAnnotator.cachedReadingFallback { _ in
            probes.withLock { count in count += 1 }
            if throwing.withLock({ state in state }) {
                throw JMDictLookupError.databaseMissing
            }
            return "あつ"
        }

        // Infrastructure failure: uncached nil, so the recovered probe
        // answers on the next call.
        #expect(fallback("圧") == nil)
        throwing.withLock { state in state = false }
        #expect(fallback("圧") == "あつ")
        #expect(probes.withLock { count in count } == 2)
    }
}
