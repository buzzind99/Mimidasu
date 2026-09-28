import Foundation
import Synchronization

/// Builds the right engine for a session: native when the runtime + model
/// resolve, mock otherwise.
enum ASREngineFactory {
    /// The warm-cache state, guarded by the factory `Mutex`.
    private struct WarmState {
        var engine: CrispASREngine?
        var path: String?
        /// Latched by `retireWarmEngine`: once retired, the factory hands out
        /// nothing, so an in-flight background warm-up cannot re-create a
        /// resident model after the quit teardown released it (freed — or
        /// deliberately left in place on a poisoned runtime, see
        /// `runtimePoisoned`).
        var retired = false
    }

    /// Process-warm engine: the loaded model stays resident for the app's
    /// lifetime so starting a session after the first one skips the
    /// multi-second GGUF load + Metal pipeline compile. Locked statics — the
    /// warm-up runs off the main actor.
    private static let warm = Mutex(WarmState())

    /// Latched when an engine `close()` had to leak its session: a
    /// decode/VAD job was still running a C call in the runtime, so the
    /// runtime's cached-model free must never run again in this process —
    /// not at this engine's quit-time retirement, and not under any engine
    /// swapped in later (the stale-model path may legitimately proceed with
    /// a new session in that runtime; only the free is unsafe). The OS
    /// reclaims the leak at exit.
    private static let runtimePoisoned = Mutex(false)

    /// `makeNative` is injectable so tests can force the native-construction
    /// failure path without dlopen state; the default builds the real engine.
    static func makeEngine(
        modelURL: URL?,
        allowMock: Bool,
        makeNative: (URL) throws -> CrispASREngine? = { modelURL in
            try CrispASREngine(modelPath: modelURL)
        }
    ) -> ASREngine? {
        if let modelURL {
            return warm.withLock { state in
                // Retired (app quitting): a warm-up racing the quit teardown
                // must not load a new resident model.
                guard !state.retired else { return nil }
                if let cached = state.engine {
                    if state.path == modelURL.path {
                        return cached
                    }
                    // Model file changed: retire the stale engine. A leaked
                    // close poisons the runtime (see `runtimePoisoned`) —
                    // the swap-in still proceeds, the user asked for the new
                    // model — but the quit-time shutdown free will be skipped.
                    if !cached.close() {
                        runtimePoisoned.withLock { poisoned in poisoned = true }
                    }
                    state.engine = nil
                    state.path = nil
                }
                if let engine = try? makeNative(modelURL) {
                    state.engine = engine
                    state.path = modelURL.path
                    return engine
                }
                return allowMock ? MockASREngine() : nil
            }
        }
        return allowMock ? MockASREngine() : nil
    }

    /// Permanently closes the warm engine's C session (freeing the resident
    /// model and its Metal contexts) and clears the cache. Called at app quit
    /// — after the session teardown has drained — so the runtime's contexts
    /// are released before process exit instead of being reported alive at
    /// Metal device teardown. No-op when nothing is cached; closing an engine
    /// that never prepared only flips its finishing flag (no open session).
    ///
    /// The runtime also keeps a process-cached FireRedVAD model resident
    /// across sessions — the second Metal residency set alive at quit — so
    /// the cache is freed too. Only when a native engine existed: never
    /// dlopen the runtime just to shut it down. No-op when the runtime lacks
    /// the symbol. Retirement latches for the rest of the process: a warm-up
    /// that was in flight when the quit began cannot re-cache an engine
    /// behind it.
    ///
    /// The runtime shutdown only follows a clean engine close on a clean
    /// runtime: when `close` had to leak the session (a decode/VAD job
    /// outlived its drain and is still running a C call in that runtime),
    /// the cached-model free is skipped as well — and the runtime stays
    /// poisoned for the rest of the process, so a later quit whose engine
    /// closed cleanly skips the free too (the leak may long predate the
    /// engine cached at that quit — e.g. a stale-model swap).
    ///
    /// `shutdownRuntime` is injectable so tests can retire a cached native
    /// engine without freeing the process-global VAD cache under the
    /// parallel live suites; the default performs the real shutdown.
    static func retireWarmEngine(shutdownRuntime: (() -> Void)? = nil) {
        var hadNativeEngine = false
        var drainedCleanly = true
        warm.withLock { state in
            hadNativeEngine = state.engine != nil
            if let engine = state.engine {
                drainedCleanly = engine.close()
                if !drainedCleanly {
                    runtimePoisoned.withLock { poisoned in poisoned = true }
                }
            }
            state.engine = nil
            state.path = nil
            state.retired = true
        }
        if hadNativeEngine, drainedCleanly, !runtimePoisoned.withLock({ poisoned in poisoned }) {
            if let shutdownRuntime {
                shutdownRuntime()
            } else {
                (try? CrispASRLibrary.open())?.shutdown()
            }
        }
    }

    /// Clears the retirement latch and the poisoned-runtime flag. Test-only:
    /// both are meant to hold for the rest of the process, but the factory
    /// suite shares one process and re-arms before every test.
    static func rearmWarmCacheForTesting() {
        warm.withLock { state in state.retired = false }
        runtimePoisoned.withLock { poisoned in poisoned = false }
    }
}
