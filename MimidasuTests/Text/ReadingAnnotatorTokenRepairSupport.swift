import Foundation
@testable import Mimidasu

// MARK: - Collapse repair fixtures

// Fixtures shared by the collapse-repair suites: the two fake tokenizers
// that stand in for a lattice collapsing long runs, and the sentences their
// windows are scripted from.

/// Stands in for the lexicon behaviour the repair exists to undo: a run too
/// long for the lattice collapses into one grouped unknown node (a nil
/// reading), while anything short enough decodes into real words. Inputs
/// listed in `decodes` replay their own payload — including an explicit nil,
/// standing in for a runtime that refused the text; anything else decodes as a
/// single unknown node spanning the whole input, which is how the real
/// tokenizer binds an unmodeled run. Every call is recorded so a test can pin
/// exactly which windows were handed to the tokenizer.
final class FakeCollapseTokenizer {
    private let decodes: [String: [DictionaryToken]?]
    private(set) var windows: [String] = []

    init(_ decodes: [String: [DictionaryToken]?] = [:]) {
        self.decodes = decodes
    }

    func tokenize(_ text: String) -> [DictionaryToken]? {
        windows.append(text)
        return decodes[text] ?? [token(text, start: 0)]
    }

    /// The annotator under a fake tokenizer, with the fallback tier's gate
    /// answering "has entry" so a repair is never shadowed by fragmentation.
    func annotator() -> ReadingAnnotator {
        ReadingAnnotator(
            tokenize: { text in self.tokenize(text) },
            readingFallback: { _ in nil },
            headwordGate: { _ in true }
        )
    }
}

/// A text-keyed table cannot tell the tokenizer's own transcript call from a
/// re-decode window when a collapse fits inside a single window — the two are
/// then literally the same string, and a table can only answer one way for
/// both. This fake separates them by call order: the first call is the
/// transcript, every call after it is a window, so a fixture can say "this
/// whole string collapses" and "this window comes back as real words" at the
/// same time.
final class ScriptedCollapseTokenizer {
    private let transcript: [DictionaryToken]
    private let decodes: [String: [DictionaryToken]?]
    private var calls = 0
    private(set) var windows: [String] = []

    init(transcript: [DictionaryToken], decodes: [String: [DictionaryToken]?] = [:]) {
        self.transcript = transcript
        self.decodes = decodes
    }

    func tokenize(_ text: String) -> [DictionaryToken]? {
        defer { calls += 1 }
        guard calls > 0 else { return transcript }
        windows.append(text)
        return decodes[text] ?? [token(text, start: 0)]
    }

    /// The annotator under this fake, with the fallback tier's gate answering
    /// "has entry" so a repair is never shadowed by fragmentation.
    func annotator() -> ReadingAnnotator {
        ReadingAnnotator(
            tokenize: { text in self.tokenize(text) },
            readingFallback: { _ in nil },
            headwordGate: { _ in true }
        )
    }
}

/// The debug sentence exactly as the real tokenizer binds it: `ち` on its own
/// (read as the verb ちる) followed by one 16-scalar unknown node, then real
/// words. The collapse starts mid-word, which is why nothing inside it is a
/// headword the fallback tier could cut at.
let debugSentence = "ちょっとまあいいんだけどさなんでや稲なりだけだからか。"

let collapsedDebugSentence: [DictionaryToken] = [
    token("ち", start: 0, reading: "ち", base: "ちる", pos: "動詞"),
    token("ょっとまあいいんだけどさなんでや", start: 1),
    token("稲", start: 17, reading: "いね", base: "稲", pos: "名詞"),
    token("なり", start: 18, reading: "なり", base: "なり", pos: "助詞"),
    token("だけ", start: 20, reading: "だけ", base: "だけ", pos: "助詞"),
    token("だ", start: 22, reading: "だ", base: "だ", pos: "助動詞"),
    token("から", start: 23, reading: "から", base: "から", pos: "助詞"),
    token("か", start: 25, reading: "か", base: "か", pos: "助詞"),
    token("。", start: 26, reading: "。", base: "。", pos: "記号")
]

/// The windows an accepted attempt decodes, plus the bare region's first
/// window — which still comes back as an 8-scalar unknown node, the smallest
/// run the fallback tier would have to guess a cut inside.
func collapseWindows() -> [String: [DictionaryToken]?] {
    [
        debugSentence: collapsedDebugSentence,
        // The bare region caps out at 12 + 4 scalars, and the first window
        // still collapses — which is why the attempt has to grow left.
        "ょっとまあいいんだけどさ": [token("ょっとまあいいんだけどさ", start: 0)],
        "なんでや": tokens(["なんで", "や"], readings: ["なんで", "や"], bases: ["なんで", "や"]),
        "ちょっとまあいいんだけど": tokens(
            ["ちょっと", "まあ", "いい", "ん", "だ", "けど"],
            readings: ["ちょっと", "まあ", "いい", "ん", "だ", "けど"],
            bases: ["ちょっと", "まあ", "いい", "ん", "だ", "けど"]
        ),
        "さなんでや": tokens(
            ["さ", "な", "ん", "で", "や"],
            readings: ["さ", "な", "ん", "で", "や"],
            bases: ["さ", "だ", "ん", "だ", "や"]
        )
    ]
}

/// A synthetic collapse wide enough to reach the threshold, with the real
/// segmentation hiding inside it.
let syntheticCollapse = "がっこうへいきます"

func syntheticWindows() -> [String: [DictionaryToken]?] {
    [
        syntheticCollapse: tokens(
            ["がっこう", "へ", "いきます"],
            readings: ["がっこう", "へ", "いきます"],
            bases: ["学校", "へ", "行く"]
        )
    ]
}

/// The bare region still collapses, so a repair at that token has to reach the
/// next rung of the ladder to be accepted. `syntheticWindows` on its own is
/// useless for testing anything below the first rung — the bare region decodes
/// cleanly there, so the left-context walk never starts and a test built on it
/// cannot tell a working walk from no walk at all.
func stillCollapsingWindows() -> [String: [DictionaryToken]?] {
    var decodes = syntheticWindows()
    decodes[syntheticCollapse] = [token(syntheticCollapse, start: 0)]
    return decodes
}

/// A kana run exactly at the collapse threshold — the shortest one the pass
/// looks at, and the shape repeated-vocable ASR garble takes. Spelled as a
/// repeat so the length is stated rather than counted, and the decode it
/// recovers into is derived from the same number.
let kanaRun = String(repeating: "い", count: 8)
let kanaRunWords = [String](repeating: "いい", count: 4)
