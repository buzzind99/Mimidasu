import Synchronization

/// Pure-Swift stand-in used when the native runtime is unavailable. Emits
/// canned transcripts in rotation, gated by the audio energy (simple RMS
/// threshold) so the
/// full pipeline — buffering, translation, UI, export — stays exercisable.
/// Only the texts are deterministic: the sentence cadence is randomized
/// (5–12 speech chunks). The UI labels mock sessions clearly.
///
/// `@unchecked Sendable`: the mutable engine state lives in `state`, guarded
/// by a `Mutex`. `push` runs on the capture queue, `poll` on the main actor's
/// poll timer, and `finish` in a detached teardown task — poll and finish can
/// overlap, so the mutex is the confinement the compiler cannot infer.
final class MockASREngine: ASREngine, @unchecked Sendable {
    let isMock = true
    var onEngineError: ((String) -> Void)?

    private static let canned = [
        "今日はいい天気ですね。",
        "これから配信を始めます、よろしくお願いします。",
        "新しいゲーム、みんな遊んだ？",
        "チャットの質問に答えていきますね。",
        "次の話題に移ります、面白いですよ。"
    ]

    private struct State {
        var speechChunksSeen = 0
        var nextSentenceAt = 6
        var pendingFinal: String?
        var cannedIndex = 0
        var totalSamples = 0
        var lastFinalEnd = 0
    }

    private let state = Mutex(State())

    var processedSamples: Int {
        state.withLock { current in current.totalSamples }
    }

    var pushedSamples: Int {
        state.withLock { current in current.totalSamples }
    }

    func prepare() throws(ASREngineError) {}
    func openStream() throws(ASREngineError) {}

    func push(_ samples: [Float]) {
        let isSpeech = AudioLevels.rms(of: samples) > AudioLevels.silenceFloorRMS
        state.withLock { current in
            current.totalSamples += samples.count
            if isSpeech {
                current.speechChunksSeen += 1
            }
            if current.pendingFinal == nil, current.speechChunksSeen >= current.nextSentenceAt {
                current.pendingFinal = Self.canned[current.cannedIndex % Self.canned.count]
                current.cannedIndex += 1
                current.nextSentenceAt = current.speechChunksSeen + Int.random(in: 5 ... 12)
            }
        }
    }

    func poll() -> ASREvent? {
        state.withLock { current in
            guard let text = current.pendingFinal else { return nil }
            current.pendingFinal = nil
            let end = current.totalSamples
            let start = current.lastFinalEnd
            current.lastFinalEnd = end
            return .final(text: text, startSample: start, endSample: end, lang: "ja")
        }
    }

    func finish() -> [ASREvent] {
        // Parity with the real engine: an undelivered pending final is
        // flushed (same span construction as `poll`) and then cleared.
        guard let event = poll() else { return [] }
        return [event]
    }

    func flushUtterance() -> [ASREvent] {
        // Parity with the real engine's pause flush: an undelivered pending
        // final lands as a sentence; nothing else is latched, so pushes
        // resume cleanly.
        finish()
    }
}
