@testable import Mimidasu
import Testing

/// Pins all three `ASREngineError` descriptions (surfaced verbatim to the
/// user via `AppModel`'s `onEngineError` / `.needsModel` paths).
@Suite("ASREngineError")
struct ASREngineErrorTests {

    struct Row: Sendable {
        let summary: String
        let error: ASREngineError
        let expected: String
    }

    @Test("descriptions pin the user-facing copy", arguments: [
        Row(
            summary: "runtimeNotFound includes the build hint",
            error: .runtimeNotFound("dlopen failed: image not found"),
            expected: "ASR runtime not found (dlopen failed: image not found). Build it with "
                + "scripts/build_runtime.sh, or drop the GGUF into the models folder to use the mock."
        ),
        Row(
            summary: "modelNotFound includes the path",
            error: .modelNotFound("/tmp/nope.gguf"),
            expected: "ASR model not found at /tmp/nope.gguf."
        ),
        Row(
            summary: "createFailed includes the detail",
            error: .createFailed("crispasr_session_open_explicit failed (backend parakeet)"),
            expected: "Failed to create ASR recognizer: crispasr_session_open_explicit failed (backend parakeet)"
        )
    ])
    func descriptions(row: Row) {
        #expect(row.error.errorDescription == row.expected, "\(row.summary)")
    }
}
