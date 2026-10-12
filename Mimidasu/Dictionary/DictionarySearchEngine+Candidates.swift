import Foundation

/// What one query turns into: candidate writings, the romaji conversions behind
/// them, and the lemma retry's tokenizer probe. Kept apart from the ladder so
/// both files stay inside the type-body budget.
extension DictionarySearchEngine {

    // MARK: - Candidates

    /// Every headword probe one query implies.
    ///
    /// Japanese input probes its own script plus the kana mirrors that make
    /// マケル reach まける and vice versa — and, prefix-stage only, the
    /// script-switch shapes that reach readings written in both scripts. Latin
    /// input goes through the romaji
    /// converter instead: a fully consumed spelling is both an exact seek and
    /// a prefix scan (`kyou` reaches きょう *and* きょうか…), and an
    /// unfinished one expands its trailing consonant into every mora it can
    /// begin (`mak` → まか…まこ). The spelling itself probes too, its
    /// uppercased form alongside: digits (`4649`) have no romaji reading, and
    /// stored Latin keeps its case (`TKG`) where queries arrive
    /// lowercased, so the headword a spelling names is only reachable
    /// through its own shape — or through the spellings that fold onto it
    /// (`caseHeadwords`), which is what reaches `ActiveX` from `activex`.
    /// Both branches run that rescue — a mixed-script query (`abc順`) is the
    /// shape that needs it on the Japanese side, where the early return
    /// skips the romaji converter and the literal spellings alike.
    /// The parameter is required, not defaulted: the set is read from the
    /// opened handle and forgetting to pass it along would silently drop
    /// every mixed-case headword from reach.
    static func headwordCandidates(
        for query: String, caseHeadwords: CaseHeadwordSpellings
    ) -> [HeadwordCandidate] {
        var out: [HeadwordCandidate] = []
        var seen: Set<String> = []
        func add(_ writing: String, probe: DictionarySearchProbe,
                 matchKind: DictionarySearchHit.MatchKind, highlight: Int)
        {
            guard !writing.isEmpty else { return }
            let key = "\(probe.rawValue)\u{1}\(matchKind.rawValue)\u{1}\(writing)"
            guard seen.insert(key).inserted else { return }
            out.append(HeadwordCandidate(
                text: writing, probe: probe, matchKind: matchKind, highlightScalars: highlight
            ))
        }
        if KanaClassification.containsJapanese(query) {
            let typed = query.unicodeScalars.count
            for writing in writingVariants(of: query) {
                add(writing, probe: .exact, matchKind: .exact, highlight: typed)
                add(writing, probe: .prefix, matchKind: .prefix, highlight: typed)
                // Mixed-script readings sit outside the range of their own
                // all-hiragana prefix, so the whole-string probes above
                // cannot reach them; the switch probes each agree with the
                // reading on one more scalar, and the scan ignores the rest.
                for probe in KanaRomaji.scriptSwitchProbes(of: writing) {
                    add(probe, probe: .prefix, matchKind: .prefix, highlight: typed)
                }
            }
            // A mixed-script query (`abc順`) lowercases away the case the
            // stored spelling keeps (`ABC順`), and the B-tree's BINARY order
            // puts that spelling outside both of the whole-string probes
            // above. The folded spellings rescue it the way they rescue
            // `activex` on the Latin branch.
            emitCaseSpellingCandidates(
                for: query, caseHeadwords: caseHeadwords, highlight: typed, add: add
            )
            return out
        }
        for conversion in romajiConversions(for: query) {
            emitRomajiCandidates(conversion, add: add)
        }
        out += literalCandidates(for: query, caseHeadwords: caseHeadwords)
        return out
    }

    /// One conversion's probes: every reading it offers — the primary kana,
    /// the long-vowel/loanword/prolonged-sound variants — as exact and prefix
    /// candidates when fully consumed, the script-switch shapes beside them,
    /// and the trailing-onset expansions when the scan stopped on a promise.
    private static func emitRomajiCandidates(
        _ conversion: KanaRomaji.RomajiConversion,
        add: (_ writing: String, _ probe: DictionarySearchProbe,
              _ matchKind: DictionarySearchHit.MatchKind, _ highlight: Int) -> Void
    ) {
        for kana in [conversion.kana] + conversion.variants {
            let typed = kana == conversion.kana
                ? conversion.typedScalarCount
                : kana.unicodeScalars.count
            if conversion.fullyConsumed {
                for writing in writingVariants(of: kana) {
                    add(writing, .exact, .exact, typed)
                    add(writing, .prefix, .prefix, typed)
                }
                // The dash variants ride in `variants`, so every form the
                // probes issue from — こおひい and its こーひー — is already
                // in this loop; the mark is script-neutral, so a probe on
                // the dash form aligns with the marked reading.
                for probe in KanaRomaji.scriptSwitchProbes(of: kana) {
                    add(probe, .prefix, .prefix, typed)
                }
            }
            if let onset = conversion.trailingOnset {
                for mora in KanaRomaji.onsetExpansions(onset) {
                    for writing in writingVariants(of: kana + mora) {
                        add(writing, .prefix, .prefix, typed)
                    }
                }
            }
        }
    }

    /// The spelling probes that reach the writings stored verbatim — numeric
    /// (4649, 4コマ) and Latin (TKG, www) headwords no kana conversion can
    /// spell: the query as typed and its uppercase form, each as an exact seek
    /// and a prefix scan. Queries arrive lowercased while those rows keep their
    /// case, and the uppercase spelling only rescues the all-caps half of it —
    /// `ActiveX` and `iPhone` are mixed case, so `caseHeadwords` answers for
    /// them the way the uppercase form answers for `TKG`: the stored spelling
    /// itself, probed as an exact seek when its fold is the query and as a
    /// prefix scan when the query merely opens it (`iph` → `iPhone`).
    ///
    /// Deduplicated against the typed and uppercase spellings, which the
    /// two-spelling shape could afford to skip: a folded spelling can carry
    /// kana (`1Dayコンタクト`), and once the two sets can intersect, emitting
    /// the same writing twice would spend a second seek proving what the first
    /// one already knew. The rescue itself is shared with the Japanese branch
    /// (`emitCaseSpellingCandidates`), which runs it before its early return —
    /// only this function runs on the Latin branch.
    static func literalCandidates(
        for query: String, caseHeadwords: CaseHeadwordSpellings
    ) -> [HeadwordCandidate] {
        let typed = query.unicodeScalars.count
        var spellings = [query]
        let upper = query.uppercased()
        if upper != query {
            spellings.append(upper)
        }
        var out: [HeadwordCandidate] = []
        var seen: Set<String> = []
        func add(_ writing: String, _ probe: DictionarySearchProbe) {
            let key = "\(probe.rawValue)\u{1}\(writing)"
            guard seen.insert(key).inserted else { return }
            out.append(HeadwordCandidate(
                text: writing, probe: probe,
                matchKind: probe == .exact ? .exact : .prefix, highlightScalars: typed
            ))
        }
        for spelling in spellings {
            for writing in writingVariants(of: spelling) {
                add(writing, .exact)
                add(writing, .prefix)
            }
        }
        emitCaseSpellingCandidates(
            for: query, caseHeadwords: caseHeadwords, highlight: typed
        ) { writing, probe, _, _ in
            add(writing, probe)
        }
        return out
    }

    /// The case-bearing spellings the folded query reaches, probed one at a
    /// time: a spelling whose fold is the query itself is both an exact seek
    /// and a prefix scan, one the query merely opens is a prefix scan alone.
    /// The one rescue both branches run — the Japanese branch returns before
    /// the literal spellings are ever built, and its mixed-script queries are
    /// exactly the shape that needs the set.
    private static func emitCaseSpellingCandidates(
        for query: String, caseHeadwords: CaseHeadwordSpellings, highlight: Int,
        add: (_ writing: String, _ probe: DictionarySearchProbe,
              _ matchKind: DictionarySearchHit.MatchKind, _ highlight: Int) -> Void
    ) {
        for match in caseHeadwords.matches(openingFold: query) {
            for writing in writingVariants(of: match.spelling) {
                if match.isExact {
                    add(writing, .exact, .exact, highlight)
                    // The exact-tier seek already answers for the spelling
                    // itself, but the prefix scan is what reaches the longer
                    // spellings that start with it (`iPhone` → `iPhones`), the
                    // way it does for every other spelling probed here.
                    add(writing, .prefix, .prefix, highlight)
                } else {
                    add(writing, .prefix, .prefix, highlight)
                }
            }
        }
    }

    /// The writing as typed, its kana-folded form, and — when the result is
    /// pure kana — its katakana mirror. Kanji-bearing input is left alone:
    /// mirroring half a string (負ケル) probes a spelling nothing carries.
    static func writingVariants(of text: String) -> [String] {
        var out = [text]
        var seen: Set<String> = [text]
        func add(_ writing: String) {
            guard seen.insert(writing).inserted else { return }
            out.append(writing)
        }
        add(ReadingAlignment.foldedKana(text))
        // The mirror can land back on the spelling as typed (アソコ folds to
        // あそこ and mirrors to アソコ again), and a duplicate candidate would
        // spend a second primary-key seek proving what the first one knew.
        let kana = out[out.count - 1]
        if kana.unicodeScalars.allSatisfy(KanaClassification.isKana) {
            add(KanaRomaji.katakanaMirror(kana))
        }
        return out
    }

    /// The first word's romanization — a multi-word latin query names one
    /// headword at best, so the leading token is the only honest candidate.
    static func romajiConversions(for query: String) -> [KanaRomaji.RomajiConversion] {
        let token = query.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? query
        guard let conversion = KanaRomaji.convert(token) else { return [] }
        return [conversion]
    }

    /// Whether the query's leading romaji token fully converts to kana — the
    /// lemma gate's romaji arm. A trailing-onset-only conversion (`mak` → ま
    /// plus a `k` promise) is still an unfinished spelling, not a word to
    /// lemmatize, so only a fully consumed conversion counts.
    static func hasFullyConsumedRomaji(_ query: String) -> Bool {
        romajiConversions(for: query).contains { conversion in conversion.fullyConsumed }
    }

    /// The romaji bridge for the lemma retry: lemmatizes each fully-consumed
    /// conversion's primary kana the way `lemmaBaseCandidates` lemmatizes a
    /// kana query. Converted variants ride the exact/prefix probes already;
    /// probing their lemmas too is a fan-out decision for later, not this
    /// bridge. Candidates whose (probe, text) an exact/prefix probe already
    /// covers are dropped — the exact tier already answers for a
    /// dictionary-form spelling, and a second seek would only prove it again.
    /// Literal and case spellings are Latin while lemma texts are Japanese,
    /// so only the kana probes need covering. The potential unwrap rides
    /// separately via `includeUnwrap` so the ladder can probe the base first
    /// and the unwrap only on a miss.
    static func romajiLemmaCandidates(
        for query: String, tokenize: @Sendable (String) -> [DictionaryToken]?,
        includeUnwrap: Bool = true
    ) -> [HeadwordCandidate] {
        let conversions = romajiConversions(for: query).filter { conversion in
            conversion.fullyConsumed
        }
        guard !conversions.isEmpty else { return [] }
        return romajiLemmaCandidates(
            for: conversions, probed: romajiProbedPairs(for: conversions)
        ) { kana in
            lemmaCandidates(for: kana, tokenize: tokenize, includeUnwrap: includeUnwrap)
        }
    }

    /// The conversions overload behind the query overload above: the ladder
    /// hoists one `romajiConversions` and shares it between its gate
    /// check and both lemma stages instead of re-scanning the spelling. Each
    /// conversion's lemmas come from the `lemmas` closure so callers choose
    /// the base or unwrap shape per stage; this core only filters
    /// already-covered (probe, text) pairs.
    static func romajiLemmaCandidates(
        for conversions: [KanaRomaji.RomajiConversion],
        probed: Set<String>,
        lemmas: @Sendable (String) -> [HeadwordCandidate]
    ) -> [HeadwordCandidate] {
        var seen: Set<String> = []
        var out: [HeadwordCandidate] = []
        for conversion in conversions {
            for lemma in lemmas(conversion.kana) {
                let key = "\(lemma.probe.rawValue):\(lemma.text)"
                guard !probed.contains(key), seen.insert(key).inserted else { continue }
                out.append(lemma)
            }
        }
        return out
    }

    /// The (probe, text) pairs the headword stages already cover for these
    /// conversions: every converted reading's writings as exact + prefix, and
    /// the script-switch shapes as prefix-only. Shared by the query overload
    /// and the ladder's hoisted path so both filter identically.
    static func romajiProbedPairs(
        for conversions: [KanaRomaji.RomajiConversion]
    ) -> Set<String> {
        var probed: Set<String> = []
        for conversion in conversions {
            for kana in [conversion.kana] + conversion.variants {
                for writing in writingVariants(of: kana) {
                    probed.insert("\(DictionarySearchProbe.exact.rawValue):\(writing)")
                    probed.insert("\(DictionarySearchProbe.prefix.rawValue):\(writing)")
                }
                for probe in KanaRomaji.scriptSwitchProbes(of: kana) {
                    probed.insert("\(DictionarySearchProbe.prefix.rawValue):\(probe)")
                }
            }
        }
        return probed
    }

    /// The tokenizer's reading of an inflected form: its content token's base
    /// writing and kana reading, probed as a lemma retry. Bound tokens are
    /// skipped — a bound token (助動詞, non-independent verb, `ない`)
    /// lemmatizes away from the surface the user typed, so the resulting hit
    /// would be about a word they never searched for. The potential unwrap is
    /// a fallback, not a co-probe: callers that rank across entries must probe
    /// the base first (`includeUnwrap: false`) and the unwrap only when the
    /// base misses, or a dictionary -える verb (入れる → 入る, くれる → くる)
    /// outranks the genuine base on commonness/length. This combined shape
    /// stays for direct unit tests; the ladder uses the split arms below.
    static func lemmaCandidates(
        for query: String, tokenize: @Sendable (String) -> [DictionaryToken]?,
        includeUnwrap: Bool = true
    ) -> [HeadwordCandidate] {
        let base = lemmaBaseCandidates(for: query, tokenize: tokenize)
        guard includeUnwrap else { return base }
        let unwrap = potentialUnwrapCandidates(for: query, tokenize: tokenize)
        guard !unwrap.isEmpty else { return base }
        var seen = Set(base.map { candidate in "\(candidate.probe.rawValue):\(candidate.text)" })
        var out = base
        for candidate in unwrap {
            let key = "\(candidate.probe.rawValue):\(candidate.text)"
            guard seen.insert(key).inserted else { continue }
            out.append(candidate)
        }
        return out
    }

    /// The base + folded-reading probes of the first content token.
    static func lemmaBaseCandidates(
        for query: String, tokenize: @Sendable (String) -> [DictionaryToken]?
    ) -> [HeadwordCandidate] {
        guard let content = lemmaContentToken(for: query, tokenize: tokenize) else { return [] }
        var writings: [String] = []
        if let base = content.base, !base.isEmpty {
            writings.append(base)
        }
        if let reading = content.reading.map(ReadingAlignment.foldedKana),
           !reading.isEmpty
        {
            writings.append(reading)
        }
        return lemmaProbes(for: writings)
    }

    /// The unwrapped-potential probe of the first content token's base, or
    /// empty when the base doesn't shape like a potential/passive. IPADIC
    /// lexicalizes potentials and passives with the inflected form itself as
    /// the base (作れる, 書かれる), while headwords carry the source verb
    /// (作る, 書く) — without this fallback the lemma probe misses.
    static func potentialUnwrapCandidates(
        for query: String, tokenize: @Sendable (String) -> [DictionaryToken]?
    ) -> [HeadwordCandidate] {
        guard let content = lemmaContentToken(for: query, tokenize: tokenize),
              let base = content.base, !base.isEmpty,
              let unwrapped = JMDictExpansion.dictionaryForm(ofPotential: base),
              !unwrapped.isEmpty
        else { return [] }
        return lemmaProbes(for: [unwrapped])
    }

    /// The first content token: a token carrying a base form that is not
    /// bound. Shared by the base and unwrap arms so both read the same word.
    private static func lemmaContentToken(
        for query: String, tokenize: @Sendable (String) -> [DictionaryToken]?
    ) -> DictionaryToken? {
        tokenize(query)?.first(where: { token in
            token.base != nil && token.bound != true
        })
    }

    /// Exact-only lemma probes for each writing, deduplicated across
    /// kana variants. A lemma hit means a headword of the entry *is* the
    /// query's dictionary form: a prefix extension (a compound, a derivation,
    /// a coincidental longer spelling) is a different word, so it must never
    /// ride the lemma tier — a stem-shaped probe like たべ from たべます
    /// previously badged every たべ* headword (食べ汚す, …) LEMMA. Every
    /// probe is badge-only (`highlightScalars: 0`): the retry matched
    /// something the user never typed.
    private static func lemmaProbes(for writings: [String]) -> [HeadwordCandidate] {
        guard !writings.isEmpty else { return [] }
        var out: [HeadwordCandidate] = []
        var seen: Set<String> = []
        for writing in writings {
            for variant in writingVariants(of: writing) where seen.insert(variant).inserted {
                out.append(HeadwordCandidate(
                    text: variant, probe: .exact,
                    matchKind: .lemma, highlightScalars: 0
                ))
            }
        }
        return out
    }
}
