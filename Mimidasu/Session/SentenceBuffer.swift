import Foundation

/// Finalizes each ASR final as exactly one sentence.
///
/// Boundaries are decided above the text: the engine ends an utterance at the
/// VAD-confirmed silence endpoint, at the forced-final cap, or on a pause/stop
/// flush, so a final already covers the utterance it belongs to. The buffer
/// therefore never holds text open, never merges finals, and never re-splits a
/// final by punctuation, clause word, or length — one final in, one sentence
/// out.
///
/// All calls must happen on one actor/queue (driven on the MainActor by
/// `SessionController`).
final class SentenceBuffer {
    /// Next sentence index; advances only for emitted sentences.
    private(set) var nextIndex = 0

    var onSentence: ((Sentence) -> Void)?

    /// Emits `piece` as the next sentence, stamped with the final's audio span.
    func append(finalText piece: String, startSample: Int, endSample: Int) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Self.hasContent(trimmed) else { return }
        let sentence = Sentence(
            index: nextIndex,
            startS: SessionClock.seconds(startSample),
            endS: SessionClock.seconds(max(endSample, startSample)),
            lang: "ja",
            text: trimmed
        )
        nextIndex += 1
        onSentence?(sentence)
    }

    /// Scalars inside the kana blocks that carry no word content on their
    /// own: the voicing marks, the middle dot ・, and the long-vowel mark ー.
    /// A final made only of these (e.g. "・・・") is a symbol row, not speech.
    private static let standaloneMarks: Set<UInt32> = [0x3099, 0x309A, 0x30FB, 0x30FC]

    /// True if the string contains at least one "content" character (Japanese
    /// script via `KanaClassification`, Latin letter, or digit).
    /// Punctuation/symbol-only strings (e.g. "...", "・・・") are not worth a
    /// row or a translation.
    private static func hasContent(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            if Self.standaloneMarks.contains(scalar.value) {
                return false
            }
            if KanaClassification.isKana(scalar) || KanaClassification.isKanji(scalar) {
                return true
            }
            switch scalar.value {
            case 0x30 ... 0x39, // ASCII digits
                 0x41 ... 0x5A, 0x61 ... 0x7A: // Latin letters
                return true
            default:
                return false
            }
        }
    }
}
