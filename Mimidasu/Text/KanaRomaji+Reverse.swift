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
        /// Alternate readings where the long-vowel spelling is ambiguous. The
        /// primary is never repeated here.
        let variants: [String]
        /// Whether every input character became kana. False means `kana` is a
        /// prefix of the intended word, not a conversion of it.
        let fullyConsumed: Bool
        /// A valid-but-incomplete trailing consonant cluster — the remainder is
        /// a promise the user is still typing (`k`, `sh`, `kk`), never an
        /// invalid character (`x` in `max` leaves nil).
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
    /// circumflex long vowels, whose both readings land in `variants`.
    static func convert(_ romaji: String) -> RomajiConversion? {
        let spelling = expandedLongVowels(romaji.lowercased())
        let scan = scanned(spelling)
        guard !scan.kana.isEmpty else { return nil }
        let onset = scan.leftover.isEmpty ? nil : trailingOnset(of: scan.leftover)
        // Deduped and stripped of the primary in one pass: a variant that
        // happened to convert the same way is not a second reading, it is the
        // same reading spelled differently. Sorted, so the candidate order (and
        // therefore the whole search's tie-breaks) is identical every run.
        let variants = alternateLongVowelSpellings(spelling)
            .map { alternate in scanned(alternate).kana }
        return RomajiConversion(
            kana: scan.kana,
            variants: Set(variants).subtracting([scan.kana]).sorted(),
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
        String(String.UnicodeScalarView(kana.unicodeScalars.map { scalar in
            guard (0x3041 ... 0x3096).contains(scalar.value) else { return scalar }
            return Unicode.Scalar(scalar.value + 0x60)!
        }))
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
    static func scanned(_ romaji: String) -> Scan {
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
            if let (kana, length) = syllable(at: index, in: characters) {
                scan.kana += kana
                index += length
                continue
            }
            return Scan(kana: scan.kana, leftover: String(characters[index...]))
        }
        return scan
    }

    /// The longest syllable starting at `index`, with its consumed length.
    static func syllable(at index: Int, in characters: [Character]) -> (String, Int)? {
        for length in stride(from: min(3, characters.count - index), through: 1, by: -1) {
            let end = index + length
            guard let kana = reverseSyllables[String(characters[index ..< end])] else { continue }
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
    /// an invalid trailing character (`max`), so the caller drops the chunk and
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
    /// `ou`/`uu` spelling the scanner reads, so `tōkyō` needs no macro branch
    /// of its own.
    static func expandedLongVowels(_ romaji: String) -> String {
        var out = ""
        out.reserveCapacity(romaji.count)
        for character in romaji {
            switch character {
            case "ō", "ô": out += "ou"
            case "ū", "û": out += "uu"
            default: out.append(character)
            }
        }
        return out
    }

    /// The spellings that differ from this one only in how one long `o` is
    /// written. `ou`/`oo` are the same word in two romaji systems, so both are
    /// worth a prefix scan — but only for the `o`-row, where the ambiguity
    /// actually exists; the scanner resolves `uu` to う either way.
    ///
    /// One rewrite per occurrence, never all of them at once: `toukyou` offers
    /// `tookyou` (both long `o`s read お) *and* `toukyoo` (only the second
    /// one does), and neither reading can be preferred without the database.
    /// A single `replacingOccurrences` would produce only the second — and
    /// with two `ou`s in `toukyou` it would rewrite both into `tookyoo`, a
    /// spelling no word carries.
    static func alternateLongVowelSpellings(_ spelling: String) -> [String] {
        var out: Set<String> = []
        for (needle, replacement) in [("oo", "ou"), ("ou", "oo")] {
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

// MARK: - Tables

private extension KanaRomaji {
    /// Romaji syllable → hiragana. Greedy longest-match consumes from here,
    /// which is what makes `toukyou` land on とうきょう (と + う) and
    /// `tookyou` on とおきょう (と + お) with no special-casing.
    ///
    /// Only the five vowels have one-character keys — see `scanned(_:)`.
    static let reverseSyllables: [String: String] = {
        // One conjugation row: the consonant (empty for the vowels) plus the
        // vowel sequence and the morae that pair with it.
        struct Row {
            let consonant: String
            let vowels: String
            let morae: String
        }
        var table: [String: String] = [:]
        // Each row spells out its own vowel sequence, because the y-row has
        // three morae (や ゆ よ) — zipping `aiueo` against it would pair them
        // with the wrong vowels and drop `yo` entirely.
        let rows = [
            Row(consonant: "", vowels: "aiueo", morae: "あいうえお"),
            Row(consonant: "k", vowels: "aiueo", morae: "かきくけこ"),
            Row(consonant: "g", vowels: "aiueo", morae: "がぎぐげご"),
            Row(consonant: "s", vowels: "aiueo", morae: "さしすせそ"),
            Row(consonant: "z", vowels: "aiueo", morae: "ざじずぜぞ"),
            Row(consonant: "t", vowels: "aiueo", morae: "たちつてと"),
            Row(consonant: "d", vowels: "aiueo", morae: "だぢづでど"),
            Row(consonant: "n", vowels: "aiueo", morae: "なにぬねの"),
            Row(consonant: "h", vowels: "aiueo", morae: "はひふへほ"),
            Row(consonant: "b", vowels: "aiueo", morae: "ばびぶべぼ"),
            Row(consonant: "p", vowels: "aiueo", morae: "ぱぴぷぺぽ"),
            Row(consonant: "m", vowels: "aiueo", morae: "まみむめも"),
            Row(consonant: "r", vowels: "aiueo", morae: "らりるれろ"),
            Row(consonant: "y", vowels: "auo", morae: "やゆよ"),
            // The w-row is は行 history: modern Japanese carries わ alone,
            // and the forward table spells it "wa" — without this row the
            // romaji the transcript prints (wakaru under 分かる) could never
            // be read back.
            Row(consonant: "w", vowels: "a", morae: "わ")
        ]
        for row in rows {
            for (vowel, kana) in zip(row.vowels, row.morae) {
                table[row.consonant + String(vowel)] = String(kana)
            }
        }
        let extras: [String: String] = [
            // Hepburn alternates for the sibilants.
            "si": "し", "shi": "し", "ti": "ち", "chi": "ち",
            "tu": "つ", "tsu": "つ", "di": "ぢ", "du": "づ",
            "dzu": "づ", "ji": "じ", "zi": "じ", "wo": "を",
            "wu": "う",
            // y-digraphs.
            "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
            "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
            "sha": "しゃ", "shu": "しゅ", "she": "しぇ", "sho": "しょ",
            "sya": "しゃ", "syu": "しゅ", "syo": "しょ",
            "cha": "ちゃ", "chu": "ちゅ", "che": "ちぇ", "cho": "ちょ",
            "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
            "ja": "じゃ", "ju": "じゅ", "je": "じぇ", "jo": "じょ",
            "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
            "zya": "じゃ", "zyu": "じゅ", "zyo": "じょ",
            "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
            "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
            "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
            "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
            "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
            "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
            "dya": "ぢゃ", "dyu": "ぢゅ", "dyo": "ぢょ",
            // Foreign loanword forms.
            "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
            "fya": "ふゃ", "fyu": "ふゅ", "fyo": "ふょ",
            "va": "ゔぁ", "vi": "ゔぃ", "ve": "ゔぇ", "vo": "ゔぉ",
            "vya": "ゔゃ", "vyu": "ゔゅ", "vyo": "ゔょ",
            "wi": "うぃ", "we": "うぇ", "ye": "いぇ",
            // The forward path spells ゔ "vu" (see its table), and the
            // loanword small ゅ "xu" — the only spelling ヴュ-html has.
            "vu": "ゔ", "xu": "ゅ",
            // The forward table above is Hepburn, and ふ round-trips as "fu"
            // (`furoshiki`, not `huroshiki`). "hu" stays for wapuro input; both
            // are one mora either way.
            "fu": "ふ",
            "tsa": "つぁ", "tsi": "つぃ", "tse": "つぇ", "tso": "つぉ",
            "kwa": "くぁ", "kwi": "くぃ", "kwe": "くぇ", "kwo": "くぉ"
        ]
        table.merge(extras) { _, extras in extras }
        return table
    }()

    /// Consonant cluster → the morae it can begin.
    ///
    /// A plain consonant lists its five row morae (`k` → か…こ) without its
    /// y-digraphs: an IME typing `ka` promises か, and a `ky` promise is its
    /// own cluster. A digraph lists only the digraph morae, because `sh`
    /// means し*ゃ/し*ゅ/し*ぇ/しょ — never a bare し.
    static let onsetMorae: [String: [String]] = [
        "k": ["か", "き", "く", "け", "こ"],
        "ky": ["きゃ", "きゅ", "きょ"],
        "g": ["が", "ぎ", "ぐ", "げ", "ご"],
        "gy": ["ぎゃ", "ぎゅ", "ぎょ"],
        "s": ["さ", "し", "す", "せ", "そ"],
        "sh": ["しゃ", "しゅ", "しぇ", "しょ"],
        "z": ["ざ", "じ", "ず", "ぜ", "ぞ"],
        "j": ["じゃ", "じゅ", "じぇ", "じょ"],
        "t": ["た", "ち", "つ", "て", "と"],
        "ch": ["ちゃ", "ちゅ", "ちぇ", "ちょ"],
        "ts": ["つ", "つぁ", "つぃ", "つぇ", "つぉ"],
        "d": ["だ", "ぢ", "づ", "で", "ど"],
        "dy": ["ぢゃ", "ぢゅ", "ぢょ"],
        "n": ["な", "に", "ぬ", "ね", "の"],
        "ny": ["にゃ", "にゅ", "にょ"],
        "h": ["は", "ひ", "ふ", "へ", "ほ"],
        "hy": ["ひゃ", "ひゅ", "ひょ"],
        "f": ["ふ", "ふぁ", "ふぃ", "ふぇ", "ふぉ"],
        "fy": ["ふゃ", "ふゅ", "ふょ"],
        "b": ["ば", "び", "ぶ", "べ", "ぼ"],
        "by": ["びゃ", "びゅ", "びょ"],
        "p": ["ぱ", "ぴ", "ぷ", "ぺ", "ぽ"],
        "py": ["ぴゃ", "ぴゅ", "ぴょ"],
        "m": ["ま", "み", "む", "め", "も"],
        "my": ["みゃ", "みゅ", "みょ"],
        "r": ["ら", "り", "る", "れ", "ろ"],
        "ry": ["りゃ", "りゅ", "りょ"],
        "y": ["や", "ゆ", "よ"],
        "w": ["わ"],
        "v": ["ゔぁ", "ゔぃ", "ゔぇ", "ゔぉ"],
        "c": ["か", "き", "く", "け", "こ"],
        "l": ["ら", "り", "る", "れ", "ろ"]
    ]
}
