import Foundation

/// One Favorite identity: the headword rule, the Highlight match, and the
/// Promotion lead behind a single seam.
///
/// Identity is the dictionary headword — the kanji writing when present,
/// else the reading; an empty spelling counts as absent. Homographs sharing
/// a `keb` share one row and one star. The store keeps one value current —
/// rebuilt on load and removal, folded into on add — and Star, Highlight,
/// and Promotion read that value instead of re-deriving the rule. The
/// bound-gate, kana-fold, and potential-unwrap arms live here, once, so
/// inflection and kana-match fixes land in one place.
///
/// A value on purpose: snapshots cross the resolve/promote seam (the Lookup
/// Display module never reads the store), and the render path probes without
/// touching SQLite. `keys` holds normalized headwords, `readings` the
/// kana-folded readings a favorited word can also be written as — kept apart
/// so a spelling hit never fills a star and removal stays an exact headword
/// operation.
struct FavoriteIdentity: Equatable, Sendable {
    /// Normalized headwords — the hot path. Raw spellings live on the rows.
    private(set) var keys: Set<String>
    /// Kana-folded readings of the same rows. A set, so two favorites sharing
    /// a reading collapse onto one key and neither is counted twice.
    private(set) var readings: Set<String>

    static let empty = FavoriteIdentity(keys: [], readings: [])

    init(keys: Set<String>, readings: Set<String> = []) {
        self.keys = keys
        self.readings = readings
    }

    /// The identity built from the store's rows: the load-once and removal
    /// paths. The add path uses `insert` instead — rebuilding all 8,192 keys
    /// per star turns the cap-filling loop quadratic.
    init(words: [FavoriteWord]) {
        var k: Set<String> = []
        var r: Set<String> = []
        for word in words where !word.headword.isEmpty {
            k.insert(Self.normalize(word.headword))
            if let rk = Self.readingKey(word.reading) {
                r.insert(rk)
            }
        }
        keys = k; readings = r
    }

    /// Folds one starred row in: its normalized headword key plus its reading
    /// key when it carries kana. Amortized O(1) — the add path's budget, the
    /// same inserts the store used to do inline before the rules moved here.
    mutating func insert(_ word: FavoriteWord) {
        guard !word.headword.isEmpty else { return }
        keys.insert(Self.normalize(word.headword))
        if let reading = Self.readingKey(word.reading) {
            readings.insert(reading)
        }
    }

    // MARK: - Headword

    /// The written form a star keys on: the kanji writing when present, else
    /// the reading. An empty kanji writing or reading counts as absent, so
    /// both empty reads as nil. Every JMDict
    /// row carries at least one `reb`, so nil only arrives from a hand-built
    /// entry.
    static func headword(keb: String?, reb: String?) -> String? {
        let cleanKeb = keb.flatMap { kebValue in kebValue.isEmpty ? nil : kebValue }
        let cleanReb = reb.flatMap { rebValue in rebValue.isEmpty ? nil : rebValue }
        return cleanKeb ?? cleanReb
    }

    /// An entry's written form — the identity starred, matched, and removed on.
    static func headword(of entry: JMDictEntry) -> String? {
        headword(keb: entry.keb, reb: entry.reb)
    }

    // MARK: - Folds

    /// The NFKC-decompose-then-compose fold the dictionary probe uses at its
    /// SQL boundary. Stored headwords arrive from JMDict already folded, but
    /// the probe side comes from ASR output, which can emit halfwidth
    /// katakana (`ｶﾞ` vs `ガ`).
    ///
    /// No memo: a transcript re-diff folds a couple of thousand short
    /// strings — microseconds of work, an order of magnitude below the `Set`
    /// probe it feeds.
    static func normalize(_ text: String) -> String {
        ReadingAlignment.compatibilityComposed(text)
    }

    /// The comparable form of a stored reading, or nil when it carries no kana
    /// and so can never equal a kana surface. Kana-folded, so カタカナ,
    /// halfwidth katakana, and decomposed voicing marks all compare equal
    /// against a hiragana surface.
    static func readingKey(_ reading: String?) -> String? {
        guard let reading, KanaClassification.containsKana(reading) else { return nil }
        return ReadingAlignment.foldedKana(reading)
    }

    // MARK: - Star membership

    /// Whether `headword` names a favorite. Nil and empty never match.
    func isFavorite(headword: String?) -> Bool {
        guard let headword, !headword.isEmpty else { return false }
        return keys.contains(Self.normalize(headword))
    }

    /// Whether the displayed entry's headword names a favorite — the rule the
    /// star and the removal path use, so the entry the pager leads with is the
    /// entry whose star reads filled.
    func isFavorite(_ entry: JMDictEntry) -> Bool {
        isFavorite(headword: Self.headword(of: entry))
    }

    /// Whether a fallback pill leads with a favorited entry — the pill star's
    /// probe. Reads the promoted lead: promotion already moved a favorite
    /// (when the result has one) to the front, so the lead is the only entry
    /// that can read starred, and an unpromoted result correctly reads
    /// unstarred. Pair with FavoritesPromotion.promotingFavorites, which owns
    /// the move this probe reads.
    func leads(_ result: LookupResult) -> Bool {
        guard let lead = result.entries.first else { return false }
        return isFavorite(lead)
    }

    // MARK: - Highlight match

    /// Whether a rendered segment counts as a favorite: its surface, its
    /// lemma, the lemma's potential unwrap — by spelling or, when the unwrap
    /// is kana, against the stored reading — an all-kana lemma against the
    /// stored reading, or — written in kana, where the surface *is* the
    /// reading — a stored reading. Favouring 見る therefore lights up 見た /
    /// 見ます / 見ている, favouring 勝つ lights the potential 勝て (whose
    /// lemma is 勝てる before a negative), favouring 貰う lights kana-written
    /// conjugates (もらって via its all-kana lemma, もらえる via its unwrapped
    /// form — both reaching the starred form through the stored reading
    /// もらう), and favouring 有難う lights up ありがとう, which shares no
    /// written form with it.
    ///
    /// The lemma arms skip bound tokens: they lemmatize away from what is on
    /// screen, so favouring ない would otherwise light ねえ / なきゃ / なし —
    /// conjugates the dictionary resolves to entirely different entries. A
    /// bound token still matches on its exact surface, so spoken ない — a
    /// bound token itself — lights as before.
    ///
    /// One caveat the lexicon owns, not this matcher: on the Full model
    /// (UniDic) an aspectual content verb rides a 非自立可能 subentry and
    /// arrives bound, so 行っています's 行っ stays dark for a starred 行く
    /// where the Lite model lights it. The flag is the lexicon's own
    /// self-standing judgement.
    func matches(_ segment: ReadingSegment) -> Bool {
        if !segment.surface.isEmpty, keys.contains(Self.normalize(segment.surface)) {
            return true
        }
        // The empty-surface gate is deliberate, shared with the kana arm below.
        if let lemma = segment.lemma, !segment.surface.isEmpty, !segment.isBound, !lemma.isEmpty {
            if keys.contains(Self.normalize(lemma)) {
                return true
            }
            // IPADIC lexicalizes potential forms as standalone verbs whose
            // lemma is the potential itself (勝て before なければ → 勝てる),
            // so the starred dictionary form hides behind one tail shift —
            // the same unwrap the tap lookup walks (作れる → 作る). The tail
            // map carries only genuine potential/passive shapes (え-row + る,
            // られる, あ-row + れる), so anything else — なさる, 得る —
            // unwraps to nil, and the one
            // real overlap (売れる unwraps to 売る) is a true potential
            // relation: a starred 売る lighting 売れます is this feature's
            // contract, not a collision to gate away. The unwrap matches by
            // spelling, or — a kana-written potential (もらえる) misses the
            // kanji key 貰う by spelling — through the stored reading, the
            // same bridge the kana-lemma arm below rides. A kanji dictionary
            // form folds to itself and can never equal a reading key — those
            // come from the dictionary's kana readings (`reb`) — so the
            // reading comparison only ever fires for kana unwraps.
            if let dictionaryForm = JMDictExpansion.dictionaryForm(ofPotential: lemma),
               keys.contains(Self.normalize(dictionaryForm))
               || (!readings.isEmpty
                   && readings.contains(ReadingAlignment.foldedKana(dictionaryForm)))
            {
                return true
            }
            // An all-kana lemma is the word's kana-written citation form
            // (もらって → もらう): the tokenizer matched the literal kana
            // against the lexicon's kana entry, so the lemma can never equal
            // a kanji headword (貰う) and the arms above stay dark. Bridge
            // through the stored reading — the lemma folded kana-for-kana
            // against the favorites' reading keys — so a starred 貰う lights
            // spoken もらって the way it already lights written 貰って. The
            // kana test reads the lemma's script, not the surface's — a
            // segment carrying an all-kana citation form is the same word
            // whatever script its surface rides — though the empty-surface
            // gate on the guard still applies: a segment with no surface
            // stays dark. A lemma with kanji in it never matches here —
            // a kanji citation form was already compared by spelling above,
            // and a word's reading is its dictionary's business, not a
            // second spelling guess.
            if !readings.isEmpty,
               lemma.unicodeScalars.allSatisfy(KanaClassification.isKana),
               readings.contains(ReadingAlignment.foldedKana(lemma))
            {
                return true
            }
        }
        // Kana surfaces only. A kana-written surface carries its own
        // pronunciation, so this arm is an exact text comparison against the
        // favorites' kana spellings — the kana analogue of the spelling arm
        // above, and intentionally ungated on isBound for the same reason:
        // only the lemma arms lemmatize away from what is on screen, so only
        // they gate isBound. A surface with kanji in it never matches
        // here: 置く stays dark for a favorite read おい, and a word's reading
        // is the dictionary's business, not this list's.
        guard !readings.isEmpty, !segment.surface.isEmpty,
              segment.surface.unicodeScalars.allSatisfy(KanaClassification.isKana)
        else { return false }
        return readings.contains(ReadingAlignment.foldedKana(segment.surface))
    }
}
