@testable import Mimidasu
import Testing

/// Pins the one-final-one-sentence contract: every ASR final becomes exactly
/// one sentence with the final's own audio span, and no text shape can split
/// or merge it.
@Suite("SentenceBuffer finalization")
struct SentenceBufferTests {

    // MARK: - Fixtures

    private let unpunctuatedFinal = "今日はいい天気ですね"
    private let punctuatedFinal = "今日はいい天気ですね。"
    private let shortFinal = "はい"
    private let symbolOnlyFinal = "..."
    /// 46 chars with a `けど` and a `、` inside; the removed length cap cut
    /// this at the clause boundary.
    private let clauseRichFinal =
        "今日はとても良い天気なので散歩に行きましたけど、そのあとに買い物に出かけて晩ご飯を食べました"
    /// Two inner sentence ends; the old buffer emitted this as one row and the
    /// reworked policy must not split it either.
    private let multiSentenceFinal = "はい。そうですね。また明日。"
    private let oneSecondInSamples = 16000
    private let twoSecondsInSamples = 32000
    private let fourSecondsInSamples = 64000

    // MARK: - Helpers

    /// Captures emitted sentences so each test asserts on real outputs.
    private final class SentenceSink {
        private(set) var sentences: [Sentence] = []

        func receive(_ sentence: Sentence) {
            sentences.append(sentence)
        }
    }

    private func makeSUT() -> (buffer: SentenceBuffer, sink: SentenceSink) {
        let sink = SentenceSink()
        let buffer = SentenceBuffer()
        buffer.onSentence = { sentence in sink.receive(sentence) }
        return (buffer, sink)
    }

    // MARK: - One final, one sentence

    @Test("emits one sentence immediately with the final's audio span")
    func emitsOneSentenceWithFinalSpan() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: punctuatedFinal, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )

        #expect(
            sink.sentences == [
                Sentence(index: 0, startS: 2.0, endS: 4.0, lang: "ja", text: punctuatedFinal)
            ]
        )
    }

    @Test("emits an unpunctuated final without waiting")
    func unpunctuatedFinalEmittedImmediately() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: shortFinal, startSample: 0, endSample: oneSecondInSamples)

        #expect(sink.sentences.map(\.text) == [shortFinal])
    }

    @Test("emits each final as its own sentence with its own span")
    func eachFinalGetsItsOwnSentenceAndSpan() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: shortFinal, startSample: 0, endSample: oneSecondInSamples)
        buffer.append(
            finalText: unpunctuatedFinal, startSample: oneSecondInSamples,
            endSample: twoSecondsInSamples
        )

        #expect(sink.sentences.map(\.index) == [0, 1])
        #expect(sink.sentences.map(\.startS) == [0.0, 1.0])
        #expect(sink.sentences.map(\.endS) == [1.0, 2.0])
    }

    @Test("does not merge two finals that arrive back to back")
    func backToBackFinalsStaySeparate() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: shortFinal, startSample: 0, endSample: oneSecondInSamples)
        buffer.append(
            finalText: unpunctuatedFinal, startSample: oneSecondInSamples,
            endSample: twoSecondsInSamples
        )

        #expect(sink.sentences.map(\.text) == [shortFinal, unpunctuatedFinal])
    }

    // MARK: - No text-side splits

    @Test("never splits a long clause-rich final")
    func clauseRichFinalNotSplit() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: clauseRichFinal, startSample: 0, endSample: fourSecondsInSamples
        )

        #expect(sink.sentences.map(\.text) == [clauseRichFinal])
    }

    @Test("never splits a final at an inner sentence end")
    func innerSentenceEndNotSplit() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: multiSentenceFinal, startSample: 0, endSample: fourSecondsInSamples
        )

        #expect(sink.sentences.map(\.text) == [multiSentenceFinal])
    }

    // MARK: - Content gate

    @Test("trims surrounding whitespace from the final text")
    func trimsSurroundingWhitespace() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: "  \(shortFinal)\n", startSample: 0, endSample: oneSecondInSamples
        )

        #expect(sink.sentences.map(\.text) == [shortFinal])
    }

    @Test("emits nothing for an empty final", arguments: ["", " ", " \n\t"])
    func emptyFinalNotEmitted(finalText: String) {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: finalText, startSample: 0, endSample: oneSecondInSamples)

        #expect(sink.sentences.isEmpty)
    }

    @Test("emits nothing for a symbol-only final")
    func symbolOnlyFinalNotEmitted() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: symbolOnlyFinal, startSample: 0, endSample: oneSecondInSamples)

        #expect(sink.sentences.isEmpty)
    }

    @Test("emits nothing for a final made only of kana-block marks", arguments: [
        "・・・", // middle dots
        "ーー", // long-vowel marks
        "・ー・" // mixed
    ])
    func kanaMarkOnlyFinalNotEmitted(finalText: String) {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: finalText, startSample: 0, endSample: oneSecondInSamples)

        #expect(sink.sentences.isEmpty)
    }

    @Test("does not consume an index for an empty final")
    func emptyFinalDoesNotConsumeIndex() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: "", startSample: 0, endSample: oneSecondInSamples)
        buffer.append(
            finalText: shortFinal, startSample: oneSecondInSamples, endSample: twoSecondsInSamples
        )

        #expect(sink.sentences.map(\.index) == [0])
    }

    @Test("advances the index only for emitted sentences")
    func indexAdvancesOnlyForEmittedSentences() {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: symbolOnlyFinal, startSample: 0, endSample: oneSecondInSamples)
        buffer.append(
            finalText: shortFinal, startSample: oneSecondInSamples, endSample: twoSecondsInSamples
        )
        buffer.append(
            finalText: symbolOnlyFinal, startSample: twoSecondsInSamples,
            endSample: fourSecondsInSamples
        )
        buffer.append(
            finalText: unpunctuatedFinal, startSample: fourSecondsInSamples,
            endSample: 4 * oneSecondInSamples
        )

        #expect(sink.sentences.map(\.index) == [0, 1])
    }

    // MARK: - Span

    @Test("clamps an end sample that precedes the start")
    func endBeforeStartClampedToStart() {
        let (buffer, sink) = makeSUT()

        buffer.append(
            finalText: shortFinal, startSample: fourSecondsInSamples,
            endSample: twoSecondsInSamples
        )

        #expect(sink.sentences.first?.endS == 4.0)
    }

    @Test("japanese-script finals count as content", arguments: [
        "𠀋。", // extension B
        "々々。", // iteration marks
        "髙。", // BMP compat ideograph
        "コーヒー。" // long-vowel mark beside real kana
    ])
    func japaneseScriptFinalsEmitted(finalText: String) {
        let (buffer, sink) = makeSUT()

        buffer.append(finalText: finalText, startSample: 0, endSample: oneSecondInSamples)

        #expect(sink.sentences.map(\.text) == [finalText])
    }
}
