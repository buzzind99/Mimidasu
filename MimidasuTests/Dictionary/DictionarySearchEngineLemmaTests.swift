import Foundation
@testable import Mimidasu
import Synchronization
import Testing

/// The lemma retry over the fixture database: kana inflected forms, the
/// romaji bridge through the converted kana, and the potential-form unwrap.
/// Everything here runs offline with an injected tokenizer.
@Suite("DictionarySearchEngine lemma")
final class DictionarySearchEngineLemmaTests {
    private let fixture: DictionarySearchFixture

    init() throws {
        fixture = try DictionarySearchFixture()
    }

    private var databaseURL: URL {
        fixture.url
    }

    @Test("reads an inflected form through the tokenizer's lemma")
    func lemmaRetry() throws {
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { _ in
                [DictionaryToken(
                    text: "あめた", start: 0, end: 3,
                    reading: "あめた", base: "あめ", pos: "n", bound: false
                )]
            }
        )
        defer { sut.close() }

        let outcome = try sut.search("あめた", filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in
            candidate.entSeq == 1_153_520
        })

        #expect(hit.matchKind == .lemma)
        // The badge explains a lemma row; nothing the user typed is lit up.
        #expect(hit.highlightRange == nil)
        // 飴 is kanji-written, but the lemma probe matched the *kana* row
        // (`headwords.text = 'あめ'`), so the reading is what lights up.
        #expect(hit.matchedField == .reb)
        #expect(hit.keb == "飴")
        #expect(hit.reb == "あめ")
        #expect(hit.matchKind.badgeLabel == "LEMMA")
    }

    @Test("skips a bound token's lemma, which is about a word never searched")
    func lemmaSkipsBoundTokens() throws {
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { _ in
                [DictionaryToken(
                    text: "あめ", start: 0, end: 2,
                    reading: "あめ", base: "あめ", pos: "助動詞", bound: true
                )]
            }
        )
        defer { sut.close() }

        let outcome = try sut.search("あめ", filters: DictionarySearchFilters())

        #expect(outcome.hits.map(\.entSeq) == [1_153_520, 9_990_030, 9_990_100, 15_668_307])
        #expect(outcome.hits.allSatisfy { hit in hit.matchKind != .lemma })
    }

    @Test("bridges romaji inflected forms through the converted kana's lemma",
          arguments: ["tabetai", "tabemasu"])
    func romajiLemmaBridge(query: String) throws {
        // The stub answers for the converted kana only, the way the real
        // tokenizer answers for Japanese text and stays silent for romaji —
        // a bridge that tokenized the raw query would ask for "tabetai"
        // itself and miss.
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { text in
                guard text == "たべたい" || text == "たべます" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 4,
                    reading: text, base: "たべる", pos: "動詞", bound: false
                )]
            }
        )
        defer { sut.close() }

        let outcome = try sut.search(query, filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in
            candidate.entSeq == 1_358_280
        })

        #expect(hit.matchKind == .lemma)
        #expect(hit.highlightRange == nil)
        #expect(hit.matchedField == .reb)
        #expect(hit.keb == "食べる")
        #expect(hit.reb == "たべる")
        #expect(hit.matchKind.badgeLabel == "LEMMA")
        #expect(outcome.hits.filter { candidate in candidate.entSeq == 1_358_280 }.count == 1)
    }

    @Test("still lemmatizes kana inflected forms after the unwrap change",
          arguments: ["たべたい", "たべます"])
    func kanaLemmaRegression(query: String) throws {
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { text in
                guard text == query else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 4,
                    reading: text, base: "たべる", pos: "動詞", bound: false
                )]
            }
        )
        defer { sut.close() }

        let outcome = try sut.search(query, filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in
            candidate.entSeq == 1_358_280
        })

        #expect(hit.matchKind == .lemma)
        #expect(hit.highlightRange == nil)
        #expect(hit.matchedField == .reb)
        #expect(hit.keb == "食べる")
        #expect(hit.reb == "たべる")
        #expect(hit.matchKind.badgeLabel == "LEMMA")
    }

    @Test("unwraps a られる-tail lemma onto the source verb")
    func lemmaUnwrapsRareruTail() throws {
        // IPADIC lexicalizes 食べられる with itself as the base while the
        // headword index only carries 食べる, so the retry probes the
        // unwrapped form too.
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { _ in
                [DictionaryToken(
                    text: "たべられる", start: 0, end: 5,
                    reading: "たべられる", base: "食べられる", pos: "動詞", bound: false
                )]
            }
        )
        defer { sut.close() }

        let outcome = try sut.search("たべられる", filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in
            candidate.entSeq == 1_358_280
        })

        #expect(hit.matchKind == .lemma)
        #expect(hit.highlightRange == nil)
        #expect(hit.matchedField == .keb)
        #expect(hit.keb == "食べる")
        #expect(hit.matchKind.badgeLabel == "LEMMA")
    }

    @Test("unwraps a potential-form lemma onto the source verb",
          arguments: ["つくれる", "tsukureru"])
    func lemmaUnwrapsPotentialForm(query: String) throws {
        // つくれる lexicalizes with itself as the base (the え-row shift
        // branch of the unwrap); the romaji query converts to つくれる
        // first and follows the same path. The 作る entry rides
        // `extraWords` so the other suites' row counts stay untouched.
        let fixture = try DictionarySearchFixture(
            tokenize: { text in
                guard text == "つくれる" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 4,
                    reading: text, base: "つくれる", pos: "動詞", bound: false
                )]
            },
            extraWords: [
                JMDictFixtureDatabase.FixtureWord(
                    id: "9990180",
                    kanji: [JMDictFixtureDatabase.FixtureKanji(
                        text: "作る", common: true, jlptLevel: 5, pitchAccent: nil
                    )],
                    kana: [JMDictFixtureDatabase.FixtureKana(
                        text: "つくる", common: true, appliesToKanji: ["*"],
                        jlptLevel: nil, pitchAccent: nil
                    )],
                    sense: [JMDictFixtureDatabase.FixtureSense(
                        partOfSpeech: ["v5r"], appliesToKanji: nil, appliesToKana: nil,
                        misc: nil,
                        gloss: [JMDictFixtureDatabase.FixtureGloss(
                            lang: "eng", text: "to make"
                        )]
                    )]
                )
            ]
        )

        let outcome = try fixture.outcome(query)
        let hit = try #require(outcome.hits.first { candidate in
            candidate.entSeq == 9_990_180
        })

        #expect(hit.matchKind == .lemma)
        #expect(hit.highlightRange == nil)
        #expect(hit.matchedField == .reb)
        #expect(hit.keb == "作る")
        #expect(hit.reb == "つくる")
        #expect(hit.matchKind.badgeLabel == "LEMMA")
    }

    @Test("skips the lemma retry when the exact group is off",
          arguments: ["たべたい", "tabetai"])
    func lemmaSkippedWhenExactGroupOff(query: String) throws {
        let tokenize: @Sendable (String) -> [DictionaryToken]? = { text in
            guard text == "たべたい" else { return nil }
            return [DictionaryToken(
                text: text, start: 0, end: 4,
                reading: text, base: "たべる", pos: "動詞", bound: false
            )]
        }
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: tokenize
        )
        defer { sut.close() }

        // Control: the same stub lemmatizes with the exact group on, so the
        // prefix-only assertion below is non-vacuous. The romaji arm proves
        // the converted-kana call path (see romajiLemmaBridge); a bridge
        // tokenizing the raw query would miss here too.
        let control = try sut.search(query, filters: DictionarySearchFilters())
        #expect(control.hits.contains { hit in
            hit.entSeq == 1_358_280 && hit.matchKind == .lemma
        })

        let outcome = try sut.search(
            query, filters: DictionarySearchFilters(matchGroups: [.prefix])
        )

        // たべたい has no prefix headwords in the fixture, and the lemma tier
        // folds into `.exact` — so prefix-only correctly answers empty, not
        // merely lemma-free. Pin the emptiness so a vacuous `allSatisfy` on
        // `[]` cannot hide a gating regression.
        #expect(outcome.hits.isEmpty)
        #expect(outcome.hits.allSatisfy { hit in hit.matchKind != .lemma })
    }

    @Test("skips a bound token's lemma on the romaji bridge")
    func romajiLemmaSkipsBoundTokens() throws {
        let boundTokenize: @Sendable (String) -> [DictionaryToken]? = { text in
            guard text == "たべたい" else { return nil }
            return [DictionaryToken(
                text: text, start: 0, end: 4,
                reading: text, base: "たべる", pos: "助動詞", bound: true
            )]
        }
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: boundTokenize
        )
        defer { sut.close() }

        let outcome = try sut.search("tabetai", filters: DictionarySearchFilters())

        #expect(outcome.hits.allSatisfy { hit in hit.matchKind != .lemma })

        // Control: the same surface with a content token lemmatizes, so the
        // bound assertion above is about the bound flag, not the fixture.
        let capable = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { text in
                guard text == "たべたい" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 4,
                    reading: text, base: "たべる", pos: "動詞", bound: false
                )]
            }
        )
        defer { capable.close() }

        let control = try capable.search("tabetai", filters: DictionarySearchFilters())
        #expect(control.hits.contains { hit in
            hit.entSeq == 1_358_280 && hit.matchKind == .lemma
        })
    }

    @Test("answers a dictionary-form romaji spelling without the lemma retry")
    func romajiDictionaryFormNeedsNoLemma() throws {
        // "taberu" converts onto たべる itself, which the exact stage
        // already answers — the retry never runs, so no lemma tier appears.
        // The call counter pins *which* layer suppressed the lemma: a gate
        // skip never tokenizes, while a post-hoc probed-filter would.
        let calls = Mutex(0)
        let sut = DictionarySearchEngine(
            resolveDatabase: { [url = databaseURL] in url },
            tokenize: { text in
                calls.withLock { count in count += 1 }
                guard text == "たべる" else { return nil }
                return [DictionaryToken(
                    text: text, start: 0, end: 3,
                    reading: text, base: "たべる", pos: "動詞", bound: false
                )]
            }
        )
        defer { sut.close() }

        let outcome = try sut.search("taberu", filters: DictionarySearchFilters())
        let hit = try #require(outcome.hits.first { candidate in
            candidate.entSeq == 1_358_280
        })

        #expect(hit.matchKind == .exact)
        #expect(outcome.hits.allSatisfy { hit in hit.matchKind != .lemma })
        #expect(calls.withLock { count in count } == 0)
    }

    @Test("the romaji bridge skips an unfinished spelling's trailing onset")
    func romajiLemmaSkipsTrailingOnset() {
        // "mak" converts to ま with a `k` promise — not a word to lemmatize,
        // even though the stub would read ま as まえ.
        let candidates = DictionarySearchEngine.romajiLemmaCandidates(
            for: "mak",
            tokenize: { _ in
                [DictionaryToken(
                    text: "ま", start: 0, end: 1,
                    reading: "ま", base: "まえ", pos: "n", bound: false
                )]
            }
        )

        #expect(candidates.isEmpty)
    }

    @Test("the lemma retry probes the unwrapped potential form, exact-only")
    func lemmaCandidatesProbePotentialUnwrap() {
        let tokenize: @Sendable (String) -> [DictionaryToken]? = { _ in
            [DictionaryToken(
                text: "つくれる", start: 0, end: 4,
                reading: "つくれる", base: "つくれる", pos: "動詞", bound: false
            )]
        }
        let candidates = DictionarySearchEngine.lemmaCandidates(
            for: "つくれる", tokenize: tokenize
        )

        #expect(candidates.contains { candidate in
            candidate.text == "つくる"
                && candidate.probe == .exact
                && candidate.matchKind == .lemma
                && candidate.highlightScalars == 0
        })
        // A lemma hit means a headword *is* the dictionary form: prefix
        // extensions are different words, so no lemma probe rides a prefix
        // scan — not for the unwrap, and not for the genuine base either.
        #expect(candidates.allSatisfy { candidate in candidate.probe == .exact })
        // The genuine base still probes alongside the unwrap.
        #expect(candidates.contains { candidate in
            candidate.text == "つくれる"
                && candidate.probe == .exact
                && candidate.matchKind == .lemma
        })
        // The split arms separate them: base first, unwrap as fallback.
        #expect(!DictionarySearchEngine.lemmaBaseCandidates(
            for: "つくれる", tokenize: tokenize
        ).contains { candidate in candidate.text == "つくる" })
        #expect(DictionarySearchEngine.potentialUnwrapCandidates(
            for: "つくれる", tokenize: tokenize
        ).contains { candidate in
            candidate.text == "つくる" && candidate.matchKind == .lemma
        })
    }
}
