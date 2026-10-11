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
    /// one already knew. The set is only consulted on the Latin branch — a
    /// kana-bearing query returns before this runs — so a spelling whose fold
    /// carries kana is reachable only through a kana-free prefix, never
    /// through its own exact fold.
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
        for match in caseHeadwords.matches(openingFold: query) {
            for writing in writingVariants(of: match.spelling) {
                if match.isExact {
                    add(writing, .exact)
                    // The exact-tier seek already answers for the spelling
                    // itself, but the prefix scan is what reaches the longer
                    // spellings that start with it (`iPhone` → `iPhones`), the
                    // way it does for every other spelling probed here.
                    add(writing, .prefix)
                } else {
                    add(writing, .prefix)
                }
            }
        }
        return out
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

    /// The tokenizer's reading of an inflected form: its content token's base
    /// writing and kana reading, probed as a lemma retry. Bound tokens are
    /// skipped — a 助動詞 lemmatizes away from the surface the user typed, so
    /// the resulting hit would be about a word they never searched for.
    static func lemmaCandidates(
        for query: String, tokenize: @Sendable (String) -> [DictionaryToken]?
    ) -> [HeadwordCandidate] {
        guard let tokens = tokenize(query),
              let content = tokens.first(where: { token in
                  token.base != nil && token.bound != true
              })
        else { return [] }
        var out: [HeadwordCandidate] = []
        var seen: Set<String> = []
        for writing in [content.base, content.reading.map(ReadingAlignment.foldedKana)]
            .compactMap({ text in text })
            .filter({ text in !text.isEmpty })
        {
            for variant in writingVariants(of: writing) where seen.insert(variant).inserted {
                for probe in [DictionarySearchProbe.exact, .prefix] {
                    out.append(HeadwordCandidate(
                        text: variant, probe: probe,
                        matchKind: .lemma, highlightScalars: 0
                    ))
                }
            }
        }
        return out
    }
}
