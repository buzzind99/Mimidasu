import Foundation
import Synchronization

/// One token from the dictionary tokenizer, decoded from the runtime's JSON
/// payload — `{text, start, end, reading, base, pos}`.
///
/// `start`/`end` are Unicode-scalar indices into the **original** input
/// (end-exclusive). The runtime performs no normalization, so spans must be
/// sliced via `unicodeScalars` — never `String.Index` or `Character` views.
struct DictionaryToken: Codable, Equatable {
    let text: String
    let start: Int
    let end: Int
    /// The surface's reading in hiragana (conjugated forms carry their own —
    /// 見た → 見/ミ + た/タ), or nil for unknown/unreadable surfaces (names,
    /// rare ideographs, punctuation, bare Latin).
    let reading: String?
    /// The token's dictionary base form (IPADIC 基本形 — 言った → 言う), or nil
    /// when the lexicon row has none (`*`, unknown/short rows) or the payload
    /// predates the field.
    let base: String?
    /// The token's coarse part of speech (IPADIC's first feature column —
    /// 名詞, 動詞, …), or nil when the lexicon row marks it `*` or the payload
    /// predates the field.
    let pos: String?

    init(
        text: String,
        start: Int,
        end: Int,
        reading: String?,
        base: String? = nil,
        pos: String? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.reading = reading
        self.base = base
        self.pos = pos
    }
}

/// Swift wrapper around the staged dictionary runtime. Opens one
/// per-instance dictionary handle lazily on the resolved dictionary URL
/// (`shared` is the only de-facto global) and intentionally never frees it
/// (the CrispASR keep-warm stance).
/// Every failure is fail-soft: `tokenize` returns nil and callers degrade to
/// plain text rather than crash.
///
/// Sendable by construction: `ffi` and `resolveDictionary` are set once in
/// init and never mutated; the only mutable state (`handle`) is a
/// `Mutex`-guarded open handle.
final class DictionaryEngine: Sendable {
    static let shared = DictionaryEngine()

    private let ffi: DictionaryFFI?
    private let resolveDictionary: @Sendable () -> URL?
    /// Opened on first use; a failed attempt is retried on the next call
    /// (the dictionary may still be preparing on first launch).
    private let handle = Mutex<UnsafeMutableRawPointer?>(nil)

    /// `ffi` and the dictionary resolver are injectable for tests; defaults
    /// resolve the real runtime and the store's dictionary locations.
    init(
        ffi: DictionaryFFI? = DictionaryFFI.load(),
        resolveDictionary: @escaping @Sendable () -> URL? = { DictionaryStore.resolve() }
    ) {
        self.ffi = ffi
        self.resolveDictionary = resolveDictionary
    }

    /// Tokenizes `text` into dictionary-backed tokens, or nil when the
    /// runtime, dictionary, payload, or decoding is unavailable.
    func tokenize(_ text: String) -> [DictionaryToken]? {
        guard let ffi else { return nil }
        return handle.withLock { current -> [DictionaryToken]? in
            guard let opened = openedHandle(ffi: ffi, current: &current) else { return nil }
            return ffi.tokenize(opened, text)
        }
    }

    /// Lock-held. Resolves the dictionary URL and opens the handle on first
    /// use; keeps the handle warm forever afterwards.
    private func openedHandle(
        ffi: DictionaryFFI, current: inout UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer? {
        if let handle = current {
            return handle
        }
        guard let url = resolveDictionary(), let opened = ffi.open(url.path) else {
            return nil
        }
        current = opened
        return opened
    }
}
