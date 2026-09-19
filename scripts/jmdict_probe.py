#!/usr/bin/env python3
"""Format probe for the pinned JMDict_Extended + JMnedict assets.

Stream-parses the compiled JMDict_Extended JSON and the JMnedict names JSON
and hard-fails on any mismatch with the documented input contracts — the
tripwire against silent upstream format drift (run before every DB build;
also usable standalone via `scripts/build_jmdict.sh --probe-only`).

Usage: jmdict_probe.py <jmdict_json_path> <names_json_path> <log_path>
Exit 0 = PASS, 1 = FAIL. Full report goes to <log_path>, compact summary
to stdout.
"""

import json
import re
import sys
from collections import Counter

# JMnedict name-type vocabulary (entity tokens). Unknown values are format
# drift and fail the probe.
NAME_TYPES = {
    "place", "surname", "unclass", "fem", "given", "person", "masc",
    "station", "organization", "company", "work", "product", "char",
    "serv", "fict", "ev", "group", "dei", "obj", "myth", "doc", "creat",
    "ship", "leg", "relig",
}
# Ingest scope: keep an entry when at least one type is outside this set.
NAME_SCOPE_EXCLUDED = {"unclass", "place"}
# Measured reference counts for the pinned names asset; a names pin bump
# must re-measure and update these.
NAME_REF_ENTRIES = 403272
NAME_REF_HEADWORDS = 790805
NAME_REF_ID_MAX = 9_999_990
# Word ids must stay below the JMnedict ingest offset (jmdict_build.py
# NAME_SEQ_OFFSET): the UI classifies names by ent_seq >= offset, so a word
# at or above it would silently render through the name path.
WORD_ID_CEILING = 9_999_999


def main(json_path, names_json_path, log_path):
    errors = []
    def fail(msg):
        errors.append(msg)

    def require(cond, msg):
        if not cond:
            fail(msg)
        return cond

    log = open(log_path, "w", encoding="utf-8")
    def out(line=""):
        log.write(line + "\n")

    # Stream the file: BOM stripped, header lines collected, then one word object
    # per line with a trailing comma (even the last one — the file is NOT valid
    # JSON as a whole, which is exactly why we stream instead of json.load).
    with open(json_path, "rb") as raw:
        head = raw.read(3)
        has_bom = head == b"\xef\xbb\xbf"

    out(f"BOM: {'yes (UTF-8)' if has_bom else 'NO'}")
    if has_bom:
        text = open(json_path, encoding="utf-8-sig")
    else:
        text = open(json_path, encoding="utf-8")

    # --- 1. Header ----------------------------------------------------------
    header_keys = {}
    line_no = 0
    words_line = None
    words_remainder = ""
    for line in text:
        line_no += 1
        stripped = line.strip()
        if stripped.startswith('"words"'):
            words_line = line_no
            words_remainder = stripped.split("[", 1)[1] if "[" in stripped else ""
            break
        m = re.match(r'"([A-Za-z]+)"\s*:\s*(.*?),?\s*$', stripped)
        if m:
            header_keys[m.group(1)] = m.group(2)
        elif stripped in ("{", "}"):
            continue
        else:
            fail(f"header line {line_no}: unrecognized layout: {stripped[:80]!r}")

    expected_header = ["version", "languages", "commonOnly", "dictDate",
                       "dictRevisions", "tags"]
    for key in expected_header:
        require(key in header_keys, f"header missing required key {key!r}")
    out(f"Header keys: {sorted(header_keys)}")
    out(f"'words': [ found on line {words_line}")
    require(words_line is not None, "'words': [ line not found")

    try:
        header_json = json.loads("{" + ",".join(
            f'"{k}":{v.rstrip(",")}' for k, v in header_keys.items()) + "}")
        out(f"version={header_json.get('version')} languages={header_json.get('languages')} "
            f"commonOnly={header_json.get('commonOnly')} dictDate={header_json.get('dictDate')} "
            f"dictRevisions={header_json.get('dictRevisions')}")
    except Exception as exc:
        fail(f"header JSON failed to parse: {exc}")

    # --- 2-7. Word stream ---------------------------------------------------
    # One word per line; the FIRST word sits on the "words": [ line itself, and
    # every word line carries a trailing comma (even the last). The file is NOT
    # valid JSON as a whole — stream it, strip, parse per line.
    def word_chunks(fobj, first):
        # The first word sits on the already-consumed "words": [ line.
        if first.strip():
            yield first
        started = True
        for raw in fobj:
            s = raw.strip()
            if s in ("]}", "]"):
                return
            if s:
                yield s

    WORD_KEYS = {"id", "kanji", "kana", "sense"}
    KANJI_KEYS = {"text", "common", "tags", "furigana", "jlptLevel", "pitchAccent"}
    KANA_KEYS = {"text", "common", "tags", "appliesToKanji", "jlptLevel", "pitchAccent"}
    SENSE_KEYS = {"partOfSpeech", "appliesToKanji", "appliesToKana", "misc", "gloss",
                  "related", "antonym", "field", "dialect", "info", "languageSource"}
    GLOSS_KEYS = {"lang", "gender", "type", "text"}
    FURIGANA_KEYS = {"ruby", "rt"}
    PITCH_KEYS = {"hatsuon", "accPatts", "zoPatts"}

    entries = 0
    kanji_obj_count = 0
    kana_obj_count = 0
    kana_only_entries = 0
    kanji_entries = 0
    headword_count = 0
    max_kanji = (0, None)
    max_kana = (0, None)
    id_parse_failures = 0
    word_id_over_ceiling = 0
    word_key_missing = Counter()
    kanji_key_missing = Counter()
    kana_key_missing = Counter()
    sense_key_missing = Counter()
    gloss_key_missing = Counter()
    furigana_bad = 0
    furigana_no_rt = 0
    furigana_count = 0
    jlpt_domain = Counter()
    jlpt_entries = 0
    pitch_entries = 0
    pitch_obj_count = 0
    pitch_is_list_nonempty = 0
    acc_patts_domain = Counter()
    zo_chars = Counter()
    zo_lengths = Counter()
    hatsuon_angle = 0
    hatsuon_no_angle = 0
    applies_kanji_star = 0
    applies_kanji_restricted = 0
    applies_kana_star = 0
    applies_kana_restricted = 0
    applies_kana_empty = 0
    applies_kanji_empty = 0
    gloss_langs = Counter()
    sense_count = 0
    gloss_count = 0
    kanji_common_true = 0
    kana_common_true = 0
    kana_only_common_true = 0
    spot = {"はし": [], "さかな": [], "あめ": []}
    SPOT_MAX = 12

    for stripped in word_chunks(text, words_remainder):
        line_no += 1
        if not stripped:
            continue
        # Trailing comma even on the final word line.
        if stripped.endswith(","):
            stripped = stripped[:-1]
        if not (stripped.startswith("{") and stripped.endswith("}")):
            fail(f"line {line_no}: not a single word object: {stripped[:80]!r}")
            break
        try:
            w = json.loads(stripped)
        except Exception as exc:
            fail(f"line {line_no}: word JSON failed to parse: {exc}")
            break

        entries += 1
        for key in WORD_KEYS:
            if key not in w:
                word_key_missing[key] += 1
        try:
            wid = int(w["id"])
        except (KeyError, ValueError, TypeError):
            id_parse_failures += 1
            wid = None
        if wid is not None and wid > WORD_ID_CEILING:
            word_id_over_ceiling += 1

        kobjs = w.get("kanji") or []
        robjs = w.get("kana") or []
        kanji_obj_count += len(kobjs)
        kana_obj_count += len(robjs)
        headword_count += len(kobjs) + len(robjs)
        if not kobjs and robjs:
            kana_only_entries += 1
        elif kobjs:
            kanji_entries += 1
        if len(kobjs) > max_kanji[0]:
            max_kanji = (len(kobjs), w["id"])
        if len(robjs) > max_kana[0]:
            max_kana = (len(robjs), w["id"])

        entry_has_jlpt = False
        entry_has_pitch = False

        for obj in kobjs:
            for key in KANJI_KEYS:
                if key not in obj:
                    kanji_key_missing[key] += 1
            if obj.get("common") is True:
                kanji_common_true += 1
            fg = obj.get("furigana")
            if not isinstance(fg, list):
                furigana_bad += 1
            else:
                furigana_count += len(fg)
                for fr in fg:
                    # Upstream omits `rt` when the reading equals the ruby.
                    if not isinstance(fr, dict) or "ruby" not in fr:
                        furigana_bad += 1
                    elif "rt" not in fr:
                        furigana_no_rt += 1
            jl = obj.get("jlptLevel")
            if jl is not None:
                if not require(isinstance(jl, int), f"entry {w.get('id')}: kanji jlptLevel not int: {jl!r}"):
                    continue
                jlpt_domain[jl] += 1
                entry_has_jlpt = True
            pa = obj.get("pitchAccent")
            if isinstance(pa, dict):
                if set(pa) != PITCH_KEYS:
                    fail(f"entry {w.get('id')}: kanji pitchAccent keys {sorted(pa)} != {sorted(PITCH_KEYS)}")
                    continue
                pitch_obj_count += 1
                entry_has_pitch = True
                acc_patts_domain[pa["accPatts"]] += 1
                zp = pa["zoPatts"]
                if isinstance(zp, str):
                    zo_lengths[len(zp)] += 1
                    for ch in set(zp):
                        zo_chars[ch] += 1
                hn = pa["hatsuon"]
                if isinstance(hn, str):
                    if "<" in hn or ">" in hn:
                        hatsuon_angle += 1
                    else:
                        hatsuon_no_angle += 1
            elif isinstance(pa, list):
                if pa:
                    pitch_is_list_nonempty += 1
            elif pa is not None:
                fail(f"entry {w.get('id')}: kanji pitchAccent unexpected type {type(pa).__name__}")

        for obj in robjs:
            for key in KANA_KEYS:
                if key not in obj:
                    kana_key_missing[key] += 1
            if obj.get("common") is True:
                kana_common_true += 1
                if not kobjs:
                    kana_only_common_true += 1
            jl = obj.get("jlptLevel")
            if jl is not None:
                if not require(isinstance(jl, int), f"entry {w.get('id')}: kana jlptLevel not int: {jl!r}"):
                    continue
                jlpt_domain[jl] += 1
                entry_has_jlpt = True
            pa = obj.get("pitchAccent")
            if isinstance(pa, dict):
                if set(pa) != PITCH_KEYS:
                    fail(f"entry {w.get('id')}: kana pitchAccent keys {sorted(pa)} != {sorted(PITCH_KEYS)}")
                    continue
                pitch_obj_count += 1
                entry_has_pitch = True
                acc_patts_domain[pa["accPatts"]] += 1
                zp = pa["zoPatts"]
                if isinstance(zp, str):
                    zo_lengths[len(zp)] += 1
                    for ch in set(zp):
                        zo_chars[ch] += 1
                hn = pa["hatsuon"]
                if isinstance(hn, str):
                    if "<" in hn or ">" in hn:
                        hatsuon_angle += 1
                    else:
                        hatsuon_no_angle += 1
            elif isinstance(pa, list):
                if pa:
                    pitch_is_list_nonempty += 1
            elif pa is not None:
                fail(f"entry {w.get('id')}: kana pitchAccent unexpected type {type(pa).__name__}")
            t = obj.get("text")
            if t in spot and len(spot[t]) < SPOT_MAX:
                spot[t].append(w)

        for s in w.get("sense") or []:
            sense_count += 1
            for key in SENSE_KEYS:
                if key not in s:
                    sense_key_missing[key] += 1
            ak = s.get("appliesToKanji")
            if ak == ["*"]:
                applies_kanji_star += 1
            elif isinstance(ak, list):
                if not ak:
                    applies_kanji_empty += 1
                else:
                    applies_kanji_restricted += 1
            aa = s.get("appliesToKana")
            if aa == ["*"]:
                applies_kana_star += 1
            elif isinstance(aa, list):
                if not aa:
                    applies_kana_empty += 1
                else:
                    applies_kana_restricted += 1
            for g in s.get("gloss") or []:
                gloss_count += 1
                for key in GLOSS_KEYS:
                    if key not in g:
                        gloss_key_missing[key] += 1
                gloss_langs[g.get("lang")] += 1

        if entry_has_jlpt:
            jlpt_entries += 1
        if entry_has_pitch:
            pitch_entries += 1

    out()
    out("=== REQUIRED FIELD INVENTORY ===")
    out(f"word keys missing: {dict(word_key_missing) or 'none'}")
    out(f"kanji keys missing: {dict(kanji_key_missing) or 'none'}")
    out(f"kana keys missing: {dict(kana_key_missing) or 'none'}")
    out(f"sense keys missing: {dict(sense_key_missing) or 'none'}")
    out(f"gloss keys missing: {dict(gloss_key_missing) or 'none'}")
    out()
    out("=== EXTENDED FIELD SHAPES ===")
    out(f"furigana objects (kanji[]): {furigana_count}, malformed: {furigana_bad}, "
        f"without rt: {furigana_no_rt}")
    out(f"pitchAccent dicts: {pitch_obj_count}, non-empty LISTS: {pitch_is_list_nonempty}")
    out(f"hatsuon with <> markers: {hatsuon_angle}, without: {hatsuon_no_angle}")
    out(f"zoPatts alphabet: {dict(zo_chars)}")
    out(f"zoPatts lengths: {dict(sorted(zo_lengths.items()))}")
    out()
    out("=== accPatts VALUE DOMAIN ===")
    for value, count in acc_patts_domain.most_common(40):
        out(f"  {value!r}: {count}")
    out(f"  distinct accPatts values: {len(acc_patts_domain)}")
    out()
    out("=== SPOT CHECKS (kana-text match) ===")
    for key, words in spot.items():
        out(f"-- {key} ({len(words)} shown) --")
        for w in words:
            kebs = [k.get("text") for k in w.get("kanji") or []]
            pitches = [(o.get("text"), (o.get("pitchAccent") or {}).get("accPatts"),
                        (o.get("pitchAccent") or {}).get("zoPatts"),
                        (o.get("pitchAccent") or {}).get("hatsuon"))
                       for o in w.get("kana") or []]
            out(f"  id={w.get('id')} keb={kebs} kana_pitch={pitches}")
    out()
    out("=== JLPT DOMAIN ===")
    for value, count in sorted(jlpt_domain.items(), key=lambda kv: str(kv[0])):
        out(f"  {value!r}: {count}")
    out()
    out("=== STATS ===")
    total = entries or 1
    out(f"entries: {entries}")
    out(f"headword rows (kanji[]+kana[] objects): {headword_count} "
        f"(kanji {kanji_obj_count}, kana {kana_obj_count})")
    out(f"kanji-bearing entries: {kanji_entries} ({kanji_entries/total:.1%}), "
        f"kana-only: {kana_only_entries} ({kana_only_entries/total:.1%})")
    out(f"max kanji[] length: {max_kanji[0]} (entry {max_kanji[1]}), "
        f"max kana[] length: {max_kana[0]} (entry {max_kana[1]})")
    out(f"common=true: kanji objs {kanji_common_true}, kana objs {kana_common_true} "
        f"(kana-only entries with common kana: {kana_only_common_true})")
    out(f"jlpt coverage (entries with >=1 non-null): {jlpt_entries} ({jlpt_entries/total:.1%})")
    out(f"pitch coverage (entries with >=1 dict pitchAccent): {pitch_entries} ({pitch_entries/total:.1%})")
    out(f"senses: {sense_count} (appliesToKanji *= {applies_kanji_star}, "
        f"restricted {applies_kanji_restricted}, empty {applies_kanji_empty}; "
        f"appliesToKana *= {applies_kana_star}, restricted {applies_kana_restricted}, "
        f"empty {applies_kana_empty})")
    out(f"glosses: {gloss_count}, langs: {dict(gloss_langs.most_common(10))}")
    out()

    # --- JMnedict names section ----------------------------------------------
    # Same tripwire job for the names asset. Layout differences from JMDict:
    # header keys at column 0, and the LAST entry line carries the
    # array-closing "]" glued on after the entry's "}" ("...}]"), followed by
    # a final "}" line.
    def probe_names(path):
        try:
            with open(path, "rb") as raw:
                names_has_bom = raw.read(3) == b"\xef\xbb\xbf"
            names_text = open(path, encoding="utf-8-sig" if names_has_bom else "utf-8")
        except OSError as exc:
            fail(f"names file unreadable: {exc}")
            return 0, 0

        out("=== JMnedict NAMES ===")
        out(f"names BOM: {'yes (UTF-8)' if names_has_bom else 'NO'}")

        name_header = {}
        name_line_no = 0
        words_line = None
        words_remainder = ""
        for line in names_text:
            name_line_no += 1
            stripped = line.strip()
            if stripped.startswith('"words"'):
                words_line = name_line_no
                words_remainder = stripped.split("[", 1)[1] if "[" in stripped else ""
                break
            m = re.match(r'"([A-Za-z]+)"\s*:\s*(.*?),?\s*$', stripped)
            if m:
                name_header[m.group(1)] = m.group(2)
            elif stripped in ("{", "}"):
                continue
            else:
                fail(f"names header line {name_line_no}: unrecognized layout: {stripped[:80]!r}")

        require("version" in name_header, "names header missing required key 'version'")
        require("dictDate" in name_header, "names header missing required key 'dictDate'")
        require(words_line is not None, "names 'words': [ line not found")
        out(f"version={name_header.get('version')} dictDate={name_header.get('dictDate')} "
            f"keys={sorted(name_header)}")
        if words_line is None:
            return 0, 0

        def name_chunks(fobj, first, start_line):
            # Yields (line_no, chunk) so failure messages cite the real
            # physical line: the first chunk rides the '"words": [' line
            # itself, and blank lines the generator skips still count. The
            # first chunk gets the same trailing-comma / glued-']' treatment
            # as every later line, matching the build's tolerance.
            line_no = start_line
            s = first.strip()
            if s:
                if s in ("}", "]"):
                    return
                if s.endswith("}]"):
                    yield line_no, s[:-1]
                    return
                if s.endswith(","):
                    s = s[:-1]
                if s:
                    yield line_no, s
            for raw in fobj:
                line_no += 1
                s = raw.strip()
                if not s:
                    continue
                if s in ("}", "]"):
                    return
                if s.endswith("}]"):
                    yield line_no, s[:-1]
                    return
                if s.endswith(","):
                    s = s[:-1]
                if s:
                    yield line_no, s

        entries_total = 0
        kanji_objs = 0
        kana_objs = 0
        kept = 0
        kept_headwords = 0
        kept_id_max = 0
        id_parse_failures = 0
        id_range_failures = 0
        no_kana = 0
        common_true = 0
        trans_missing_keys = Counter()
        trans_empty = 0
        typeless_trans = 0
        gloss_missing_keys = Counter()
        non_eng_glosses = 0
        gloss_objs = 0
        unknown_types = Counter()
        type_domain = Counter()
        spot_kimura = []

        for chunk_line, stripped in name_chunks(names_text, words_remainder, name_line_no):
            if not (stripped.startswith("{") and stripped.endswith("}")):
                fail(f"names line {chunk_line}: not a single entry object: {stripped[:80]!r}")
                break
            try:
                w = json.loads(stripped)
            except Exception as exc:
                fail(f"names line {chunk_line}: entry JSON failed to parse: {exc}")
                break

            entries_total += 1
            try:
                nid = int(w["id"])
            except (KeyError, ValueError, TypeError):
                id_parse_failures += 1
                nid = None
            if nid is not None and not 5_000_000 <= nid <= 9_999_990:
                id_range_failures += 1

            kobjs = w.get("kanji") or []
            robjs = w.get("kana") or []
            kanji_objs += len(kobjs)
            kana_objs += len(robjs)
            if not robjs:
                no_kana += 1
            for obj in list(kobjs) + list(robjs):
                if obj.get("common") is True:
                    common_true += 1

            types = []
            for t in w.get("translation") or []:
                if not isinstance(t, dict):
                    fail(f"names entry {w.get('id')}: translation object is not a dict")
                    continue
                if "type" not in t:
                    trans_missing_keys["type"] += 1
                else:
                    tt = t.get("type")
                    if not isinstance(tt, list):
                        fail(f"names entry {w.get('id')}: translation type is not a list: {tt!r}")
                    else:
                        # Empty type arrays exist upstream (5 entries); such
                        # entries fall to the scope filter's skip side.
                        if not tt:
                            typeless_trans += 1
                        for v in tt:
                            if not isinstance(v, str):
                                fail(f"names entry {w.get('id')}: non-string name type {v!r}")
                                continue
                            type_domain[v] += 1
                            if v not in NAME_TYPES:
                                unknown_types[v] += 1
                            types.append(v)
                if "translation" not in t:
                    trans_missing_keys["translation"] += 1
                else:
                    gl = t.get("translation")
                    if not isinstance(gl, list) or not gl:
                        trans_empty += 1
                    else:
                        for g in gl:
                            if not isinstance(g, dict):
                                fail(f"names entry {w.get('id')}: gloss object is not a dict")
                                continue
                            gloss_objs += 1
                            for key in ("lang", "text"):
                                if key not in g:
                                    gloss_missing_keys[key] += 1
                            if g.get("lang") != "eng":
                                non_eng_glosses += 1

            if any(v not in NAME_SCOPE_EXCLUDED for v in types):
                kept += 1
                kept_headwords += len(kobjs) + len(robjs)
                if nid is not None and nid > kept_id_max:
                    kept_id_max = nid

            if any(o.get("text") == "木村" for o in kobjs) and len(spot_kimura) < 4:
                spot_kimura.append(w)

        out(f"entries total: {entries_total} "
            f"(kanji objs {kanji_objs}, kana objs {kana_objs}, gloss objs {gloss_objs})")
        out(f"translation objects with empty type array: {typeless_trans} "
            f"(upstream data; such entries fall to the scope filter's skip side)")
        out(f"type occurrences over ALL entries: {dict(type_domain.most_common())}")
        out(f"name entries: {kept}")
        out(f"name headword rows (kanji+kana objects): {kept_headwords}")
        out(f"name id max: {kept_id_max}")
        out(f"name types: {','.join(sorted(type_domain))}")
        out("-- spot: 木村 --")
        for w in spot_kimura:
            kebs = [o.get("text") for o in w.get("kanji") or []]
            rebs = [o.get("text") for o in w.get("kana") or []]
            tps = [t.get("type") for t in w.get("translation") or []]
            gls = [g.get("text") for t in w.get("translation") or []
                   for g in (t.get("translation") or [])]
            out(f"  id={w.get('id')} keb={kebs} reb={rebs} types={tps} gloss={gls}")

        if id_parse_failures:
            fail(f"names: {id_parse_failures} ids failed to parse as int")
        if id_range_failures:
            fail(f"names: {id_range_failures} ids outside 5000000..9999990")
        if no_kana:
            fail(f"names: {no_kana} entries without any kana reading")
        if common_true:
            fail(f"names: {common_true} kanji/kana objects with common=true "
                 f"(expected absent — ingest hardcodes common=0)")
        if trans_missing_keys:
            fail(f"names: translation objects missing keys: {dict(trans_missing_keys)}")
        if trans_empty:
            fail(f"names: {trans_empty} translation objects with empty/missing translation (gloss) array")
        if gloss_missing_keys:
            fail(f"names: glosses missing keys: {dict(gloss_missing_keys)}")
        if non_eng_glosses:
            fail(f"names: {non_eng_glosses} non-eng glosses (gloss join assumes eng-only)")
        if unknown_types:
            fail(f"names: unknown name types (extend NAME_TYPES): {dict(unknown_types)}")
        if kept != NAME_REF_ENTRIES:
            fail(f"names: kept entries {kept} != pinned-asset reference {NAME_REF_ENTRIES} "
                 f"(re-measure the references on a names pin bump)")
        if kept_headwords != NAME_REF_HEADWORDS:
            fail(f"names: kept headword rows {kept_headwords} != pinned-asset reference "
                 f"{NAME_REF_HEADWORDS} (re-measure the references on a names pin bump)")
        if kept_id_max != NAME_REF_ID_MAX:
            fail(f"names: kept id max {kept_id_max} != pinned-asset reference {NAME_REF_ID_MAX}")
        return kept, kept_headwords

    names_kept, names_headwords = probe_names(names_json_path)
    out()

    if id_parse_failures:
        fail(f"{id_parse_failures} ids failed to parse as int")
    if word_id_over_ceiling:
        fail(f"{word_id_over_ceiling} word ids above {WORD_ID_CEILING} "
             f"(would render as name entries)")
    if word_key_missing:
        fail(f"words missing required keys: {dict(word_key_missing)}")
    if kanji_key_missing:
        fail(f"kanji objects missing required keys: {dict(kanji_key_missing)}")
    if kana_key_missing:
        fail(f"kana objects missing required keys: {dict(kana_key_missing)}")
    if sense_key_missing:
        fail(f"senses missing required keys: {dict(sense_key_missing)}")
    if gloss_key_missing:
        fail(f"glosses missing required keys: {dict(gloss_key_missing)}")
    if furigana_bad:
        fail(f"{furigana_bad} malformed furigana objects (expected shape {{'ruby', 'rt'?}})")
    if pitch_is_list_nonempty:
        fail(f"{pitch_is_list_nonempty} non-empty pitchAccent lists "
             f"(expected {{hatsuon,accPatts,zoPatts}} or [])")
    non_eng = {k: v for k, v in gloss_langs.items() if k != "eng"}
    if non_eng:
        fail(f"non-eng glosses present (lang filter must stay): {non_eng}")
    if errors:
        out(f"RESULT: FAIL ({len(errors)} problems)")
        out("")
        for e in errors[:50]:
            out(f"  - {e}")
        log.close()
        print(f"PROBE FAILED: {len(errors)} contract violations (see {log_path})")
        for e in errors[:20]:
            print(f"  - {e}")
        sys.exit(1)
    else:
        out("RESULT: PASS")
        log.close()
        print(f"    entries: {entries}  headwords: {headword_count}  senses: {sense_count}")
        print(f"    kana-only: {kana_only_entries/total:.1%}  jlpt: {jlpt_entries/total:.1%}  "
              f"pitch: {pitch_entries/total:.1%}")
        print(f"    accPatts distinct: {len(acc_patts_domain)}  jlpt values: "
              f"{sorted(jlpt_domain, key=str)}  gloss langs: {list(gloss_langs)}")
        print(f"    names: entries {names_kept}  headwords {names_headwords}")
        print("    PASS")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("usage: jmdict_probe.py <jmdict_json_path> <names_json_path> <log_path>",
              file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
