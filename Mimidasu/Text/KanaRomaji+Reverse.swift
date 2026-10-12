import Foundation

// The reverse of `KanaRomaji.romaji(fromKana:)` — the direction a *query*
// travels: the user types latin letters, the dictionary is keyed by Japanese
// text. Unlike the forward direction this one is genuinely ambiguous, so the
// result is a small set of conversions plus an explicit "incomplete" signal
// rather than one string.
//
// Lives in its own file (the forward tables already sit near the lint file
// ceiling) but extends the same `KanaRomaji` enum, so the two directions
// read as one converter.
extension KanaRomaji {
    /// What one romanized input converts to.
    ///
    /// `kana` is the primary conversion — the converted prefix, so a partial
    /// romaji (`mak`) is still useful as a prefix candidate. `variants` carry
    /// the alternate readings of an ambiguous long-vowel spelling (`ou` ↔
    /// `oo` → おう / おお); the converter cannot know which of the two exists
    /// as a headword, so it hands both to the caller rather than guessing.
    struct RomajiConversion: Equatable, Sendable {
        /// Converted prefix, hiragana, primary long-vowel spelling.
        let kana: String
        /// Alternate readings the letters cannot disambiguate: the long-vowel
        /// spellings (`ou` ↔ `oo` → おう / おお, `ee` ↔ `ei` → ええ / えい),
        /// the loanword digraphs
        /// (`ti` → てぃ beside ち), the ぢ/づ family the forward path spells
        /// with the じ/ず keys (`ji` → ぢ beside じ), the historical kana
        /// (`wi` → ゐ beside うぃ), and the prolonged-sound forms the mark
        /// hides (こーひー under こおひい). Every table applies to every
        /// long-vowel spelling. The primary is never repeated here.
        let variants: [String]
        /// Whether every input character became kana. False means `kana` is a
        /// prefix of the intended word, not a conversion of it.
        let fullyConsumed: Bool
        /// A valid-but-incomplete trailing consonant cluster — the remainder is
        /// a promise the user is still typing (`k`, `sh`, `kk`, `x`), never an
        /// invalid character (`q` in `moq` leaves nil).
        let trailingOnset: String?

        /// The morae the typed input actually consumed: what a highlight
        /// should cover, which is *not* the same as what matched (`mak`
        /// reaches まけ through an expansion but only ま was typed).
        var typedScalarCount: Int {
            kana.unicodeScalars.count
        }
    }

    /// Converts romanized input to hiragana, or nil when nothing converts at
    /// all (`mk`, `zz`). Accepts both hepburn and wapuro spellings — users
    /// type hepburn, the forward path emits wapuro — plus macrons and
    /// circumflex long vowels, read under their row's doubled-vowel spelling.
    /// The o and e rows are the two-readings rows (`ou`/`oo` → おう/おお,
    /// `ei`/`ee` → えい/ええ), and each keeps both; the other rows have one
    /// reading each.
    static func convert(_ romaji: String) -> RomajiConversion? {
        let spelling = expandedLongVowels(romaji.lowercased())
        let scan = scanned(spelling)
        guard !scan.kana.isEmpty else { return nil }
        let onset = scan.leftover.isEmpty ? nil : trailingOnset(of: scan.leftover)
        // Every long-o spelling the letters allow, the typed one first. Each is
        // read under the plain table and every alternate table, so an alternate
        // spelling carries the same family of readings its primary does.
        let spellings = [spelling] + alternateLongVowelSpellings(spelling)
        // Deduped in one pass: a reading that happens to convert the same way
        // is not a second reading, it is the same reading spelled differently.
        // The primary rides along and is stripped at the end. Sorted, so the
        // candidate order (and therefore the whole search's tie-breaks) is
        // identical every run.
        var variantKana: Set<String> = []
        for table in [reverseSyllables] + alternateSyllableTables {
            for candidate in spellings {
                variantKana.insert(scanned(candidate, table: table).kana)
            }
        }
        // The prolonged-sound mark is the last unknowable: the forward path
        // spells ー by repeating the last vowel, so the letters name the
        // plain-vowel form while the reading stores the mark. Every reading
        // above offers its dash forms — こおひい hides こーひー (コーヒー),
        // and the loanword reading てぃい hides てぃー the same way.
        for reading in [scan.kana] + variantKana {
            variantKana.formUnion(prolongedSoundVariants(of: reading))
        }
        return RomajiConversion(
            kana: scan.kana,
            variants: variantKana.subtracting([scan.kana]).sorted(),
            fullyConsumed: scan.leftover.isEmpty,
            trailingOnset: onset
        )
    }

    /// Every mora (or, for a digraph onset, every digraph mora) `onset` can
    /// begin: `"k"` → か き く け こ, `"sh"` → しゃ しゅ しぇ しょ (never a
    /// bare し — a digraph onset promises its digraph), `"kk"` → っか っき
    /// っく っけ っこ.
    ///
    /// The engine feeds each expansion back as a prefix candidate, which is
    /// what turns `mak` into まか…まこ without an FTS index.
    static func onsetExpansions(_ onset: String) -> [String] {
        let characters = Array(onset.lowercased())
        guard !characters.isEmpty else { return [] }
        let (sokuon, core) = sokuonBearingCore(characters)
        guard let morae = onsetMorae[core] else { return [] }
        return sokuon ? morae.map { mora in "っ" + mora } : morae
    }

    /// Katakana mirror of a hiragana string, clamping the scalar shift to the
    /// paired range `0x3041–0x3096` exactly as `ReadingAlignment`'s fold
    /// disciplines its own inverse: a block-wide `+0x60` would map ゛ (0x309B)
    /// and ゜ (0x309C) onto ・ (0x30FB). Kanji, Latin, and the prolonged-sound
    /// mark ー pass through untouched.
    static func katakanaMirror(_ kana: String) -> String {
        String(String.UnicodeScalarView(kana.unicodeScalars.map(mirroredScalar)))
    }

    /// The readings the prolonged-sound mark hides: the forward path spells ー
    /// by repeating the last vowel (コーヒー → `koohii`), so a typed spelling
    /// lands on the plain-vowel form (こおひい) no headword carries — the
    /// reading stores the mark itself. Rewrites mora + successor vowel into
    /// mora + ー wherever the mark could have stood: the exact inverse of the
    /// forward's handling, e taking え/い and o taking お/う because both
    /// spellings reach the same romaji. All subsets of a form's runs (more
    /// than 4: singles plus the full set), sorted, the input excluded.
    static func prolongedSoundVariants(of kana: String) -> [String] {
        let units = moraUnits(of: kana)
        let runs = prolongedRunPositions(in: units)
        guard !runs.isEmpty else { return [] }
        var subsets = runs.map { run in [run] }
        if runs.count <= 4 {
            for mask in 1 ..< (1 << runs.count) {
                var subset: [Int] = []
                for bit in 0 ..< runs.count where mask & (1 << bit) != 0 {
                    subset.append(runs[bit])
                }
                subsets.append(subset)
            }
        } else {
            subsets.append(runs)
        }
        var out: Set<String> = []
        for subset in subsets {
            var rewritten = units
            for index in subset {
                rewritten[index + 1] = "ー"
            }
            let candidate = rewritten.joined()
            if candidate != kana {
                out.insert(candidate)
            }
        }
        return out.sorted()
    }

    /// The script-switch prefix probes a kana form issues, one pair per
    /// position j ≥ 1: the form as written through j with the j-th kana
    /// mirrored, and the mirrored head with the j-th kana as written. A
    /// mixed-script reading (うべフロンティアだいがく, アパート…) sits
    /// outside the range of its own all-hiragana prefix, so no whole-string
    /// probe reaches it — but a reading is hit by whichever probe its own
    /// script agrees with on the first j + 1 scalars, and everything after
    /// that is irrelevant to a prefix scan. All-katakana and kanji-bearing
    /// forms issue nothing: the whole-string mirror already covers the
    /// pure-katakana readings, and a mixed head matches nothing.
    static func scriptSwitchProbes(of form: String) -> [String] {
        let scalars = Array(form.unicodeScalars)
        guard scalars.count >= 2,
              scalars.allSatisfy({ scalar in
                  (0x3041 ... 0x309F).contains(scalar.value) || scalar.value == 0x30FC
              })
        else { return [] }
        var out: [String] = []
        for j in 1 ..< scalars.count {
            let head = String(String.UnicodeScalarView(scalars[0 ..< j]))
            let here = String(scalars[j])
            out.append(head + katakanaMirror(here))
            out.append(katakanaMirror(head) + here)
        }
        return out
    }
}

// MARK: - Scanning

private extension KanaRomaji {
    /// One pass over the input: the kana consumed so far plus whatever
    /// stopped the scanner.
    struct Scan: Equatable {
        var kana = ""
        /// Input from the point the scanner stopped. Empty = fully consumed.
        var leftover = ""
    }

    /// Greedy longest-match over `reverseSyllables`, sokuon-aware.
    ///
    /// The scanner deliberately has no one-character consonant keys: a bare
    /// consonant is never a mora, so `mosh` stops after も with `sh` left
    /// over instead of eating the `s` as さ. Whatever is left over at that
    /// point is either a promise (`trailingOnset`) or noise (dropped).
    ///
    /// `table` swaps the syllable table for one of `alternateSyllableTables`,
    /// whose passes read a family of alternate readings — every key of each
    /// is a plain key of the same length, so all passes consume the same
    /// input and differ only in the kana they emit.
    static func scanned(
        _ romaji: String, table: [String: String] = reverseSyllables
    ) -> Scan {
        let characters = Array(romaji)
        var scan = Scan()
        var index = 0
        while index < characters.count {
            if isSokuon(at: index, in: characters) {
                scan.kana += "っ"
                index += 1
                continue
            }
            // `n` is resolved before the syllable table, which would otherwise
            // claim `na` in `nna` and hand back まな for まんな. Only a vowel
            // (or the `y` of a y-digraph) can follow into the な行; anything
            // else — the end of the input, a consonant, `n'`, another `n` —
            // makes it the moraic ん, consuming the `'` with it.
            if characters[index] == "n", !startsNRow(at: index, in: characters) {
                scan.kana += "ん"
                let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil
                index += next == "'" ? 2 : 1
                continue
            }
            if let (kana, length) = syllable(at: index, in: characters, table: table) {
                scan.kana += kana
                index += length
                continue
            }
            return Scan(kana: scan.kana, leftover: String(characters[index...]))
        }
        return scan
    }

    /// The longest syllable starting at `index`, with its consumed length.
    static func syllable(
        at index: Int, in characters: [Character], table: [String: String]
    ) -> (String, Int)? {
        for length in stride(from: min(3, characters.count - index), through: 1, by: -1) {
            let end = index + length
            guard let kana = table[String(characters[index ..< end])] else { continue }
            return (kana, length)
        }
        return nil
    }

    /// Whether the `n` at `index` begins the な行 — a vowel, or the `y` of
    /// `nya`/`nyu`/`nyo`.
    static func startsNRow(at index: Int, in characters: [Character]) -> Bool {
        guard index + 1 < characters.count else { return false }
        let next = characters[index + 1]
        return "aiueo".contains(next) || (next == "y" && index + 2 < characters.count
            && "aiueo".contains(characters[index + 2]))
    }

    /// A geminating consonant at `index`: a doubled non-`n` consonant, or the
    /// digraph geminates `tch`/`ssh` (which no single letter doubles).
    static func isSokuon(at index: Int, in characters: [Character]) -> Bool {
        guard index + 1 < characters.count else { return false }
        let doubled = characters[index] == characters[index + 1]
            && isConsonant(characters[index])
            && characters[index] != "n"
        if doubled {
            return true
        }
        guard index + 2 < characters.count else { return false }
        let digraph = String(characters[index ... (index + 2)])
        return digraph == "tch" || digraph == "ssh"
    }

    /// The remainder itself, when it is a valid but unfinished onset — nil for
    /// an invalid trailing character (`moq`), so the caller drops the chunk and
    /// searches the prefix it did convert.
    ///
    /// The whole remainder or nothing: truncating it to the longest legal
    /// *prefix* turned an English word into a kana promise. `best` scans to `べ`
    /// and leaves `st`, which is not an onset; reading its `s` as one lit up
    /// さしすせそ and their katakana mirrors, and the search for a gloss phrase
    /// came back 74 `ベスト*` rows instead of the entry the phrase names. A
    /// truncated cluster also drops whatever follows it silently (`th` → `t`),
    /// which is noise rather than a promise. The scanner tries `isSokuon` at
    /// every position before anything else, so a leftover can never begin with
    /// a doubled consonant or a `tch`/`ssh` pair — `makk` stops on the `k` its
    /// geminate did not consume, and names that.
    static func trailingOnset(of leftover: String) -> String? {
        onsetMorae[leftover] == nil ? nil : leftover
    }

    /// Splits a sokuon-bearing onset into (geminate?, remaining cluster), so
    /// `"kk"` is っ + `k` and `"tch"` is っ + `ch`.
    static func sokuonBearingCore(_ characters: [Character]) -> (Bool, String) {
        guard characters.count >= 2 else { return (false, String(characters)) }
        let digraph = characters.count >= 3 ? String(characters[0 ... 2]) : ""
        if digraph == "tch" || digraph == "ssh" {
            return (true, String(characters[1...]))
        }
        let doubled = characters[0] == characters[1]
            && isConsonant(characters[0])
            && characters[0] != "n"
        return doubled ? (true, String(characters[1])) : (false, String(characters))
    }

    static func isConsonant(_ character: Character) -> Bool {
        character.isLetter && !"aiueon".contains(character)
    }
}

// MARK: - Long vowels

private extension KanaRomaji {
    /// Replaces the macrons and circumflexes real IMEs accept with the plain
    /// doubled-vowel spelling the scanner reads (`ō` → `ou`, `ā` → `aa`), so
    /// `tōkyō` and `chīzu` need no macro branch of their own.
    static func expandedLongVowels(_ romaji: String) -> String {
        var out = ""
        out.reserveCapacity(romaji.count)
        for character in romaji {
            switch character {
            case "ā", "â": out += "aa"
            case "ī", "î": out += "ii"
            case "ē", "ê": out += "ee"
            case "ō", "ô": out += "ou"
            case "ū", "û": out += "uu"
            default: out.append(character)
            }
        }
        return out
    }

    /// The spellings that differ from this one only in how one long `o` or
    /// long `e` is written. `ou`/`oo` are the same word in two romaji systems,
    /// and Hepburn `ee` is the long `e` wapuro spells `ei` (せんせえ / せんせい),
    /// so both pairs bridge both ways; the scanner resolves `uu` to う either
    /// way, and `aa`/`ii` have one reading apiece.
    ///
    /// One rewrite per occurrence, never all of them at once: `toukyou` offers
    /// `tookyou` (both long `o`s read お) *and* `toukyoo` (only the second
    /// one does), and neither reading can be preferred without the database.
    /// A single `replacingOccurrences` would produce only the second — and
    /// with two `ou`s in `toukyou` it would rewrite both into `tookyoo`, a
    /// spelling no word carries.
    static func alternateLongVowelSpellings(_ spelling: String) -> [String] {
        var out: Set<String> = []
        for (needle, replacement) in [
            ("oo", "ou"), ("ou", "oo"), ("ee", "ei"), ("ei", "ee")
        ] {
            var index = spelling.startIndex
            while let found = spelling.range(of: needle, range: index ..< spelling.endIndex) {
                index = found.upperBound
                var alternate = spelling
                alternate.replaceSubrange(found, with: replacement)
                out.insert(alternate)
            }
        }
        return out.sorted()
    }
}

// MARK: - Prolonged-sound mark

private extension KanaRomaji {
    /// The scalar shift behind `katakanaMirror`, guarded the same way: only
    /// the paired hiragana range moves, so ゛/゜ never land on ・.
    static func mirroredScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard (0x3041 ... 0x3096).contains(scalar.value) else { return scalar }
        return Unicode.Scalar(scalar.value + 0x60)!
    }

    /// The small kana that ride their base mora (てぃ, きょ, くゎ), with the
    /// vowel each contributes.
    static let trailingSmallVowels: [Character: Character] = [
        "ぁ": "a", "ぃ": "i", "ぅ": "u", "ぇ": "e", "ぉ": "o",
        "ゃ": "a", "ゅ": "u", "ょ": "o", "ゎ": "a"
    ]

    /// Full-size kana → the row vowel the mora carries. The only full-size
    /// table emission missing here is を (the forward path prints "wo", but
    /// no stored reading carries を at all, so there is nothing a prolonged
    /// を could reach). Two more kana reach readings without a row vowel,
    /// from the scanner rather than the tables: っ (a gemination promise,
    /// unprolongable where it strands) and ん (which the forward path never
    /// prolongs).
    static let rowVowels: [Character: Character] = {
        var map: [Character: Character] = [:]
        let rows: [(String, String)] = [
            ("あいうえお", "aiueo"), ("かきくけこ", "aiueo"), ("がぎぐげご", "aiueo"),
            ("さしすせそ", "aiueo"), ("ざじずぜぞ", "aiueo"), ("たちつてと", "aiueo"),
            ("だぢづでど", "aiueo"), ("なにぬねの", "aiueo"), ("はひふへほ", "aiueo"),
            ("ばびぶべぼ", "aiueo"), ("ぱぴぷぺぽ", "aiueo"), ("まみむめも", "aiueo"),
            ("らりるれろ", "aiueo"), ("やゆよ", "auo"), ("わ", "a"), ("ゔ", "u"),
            ("ゐゑ", "ie")
        ]
        for (morae, vowels) in rows {
            for (mora, vowel) in zip(morae, vowels) {
                map[mora] = vowel
            }
        }
        return map
    }()

    /// Successor plain vowels a ー may stand for, by the mora's vowel. e
    /// takes え and い (けーき from `keeki`); o takes お and う (こーひー
    /// from `koohii`, とーきょー from `tookyoo`).
    static let prolongedSuccessors: [Character: [Character]] = [
        "a": ["あ"], "i": ["い"], "u": ["う"], "e": ["え", "い"], "o": ["お", "う"]
    ]

    /// Mora units: a base kana followed by a small vowel/y kana is one unit,
    /// so てぃい is てぃ + い and the successor vowel is testable per unit.
    static func moraUnits(of kana: String) -> [String] {
        let characters = Array(kana)
        var units: [String] = []
        var index = 0
        while index < characters.count {
            if index + 1 < characters.count, trailingSmallVowels[characters[index + 1]] != nil {
                units.append(String(characters[index ... index + 1]))
                index += 2
            } else {
                units.append(String(characters[index]))
                index += 1
            }
        }
        return units
    }

    /// Positions whose unit is a mora or digraph followed by a plain vowel
    /// its prolonged-sound mark could have absorbed.
    static func prolongedRunPositions(in units: [String]) -> [Int] {
        var out: [Int] = []
        for index in 0 ..< max(0, units.count - 1) {
            let unit = Array(units[index])
            guard let vowel = unit.count == 2
                ? trailingSmallVowels[unit[1]]
                : rowVowels[unit[0]],
                let allowed = prolongedSuccessors[vowel],
                units[index + 1].count == 1,
                let next = units[index + 1].first,
                allowed.contains(next)
            else { continue }
            out.append(index)
        }
        return out
    }
}
