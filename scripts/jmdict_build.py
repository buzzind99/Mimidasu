#!/usr/bin/env python3
"""Build the JMDict lookup DB from the pinned JMDict_Extended + JMnedict assets.

Consumes the stream-parsed JSON (already probe-passed by jmdict_probe.py —
the run that emits the probe report must have used these exact files),
writes the SQLite schema (JMDict words + JMnedict names in the same tables,
names on a +10M ent_seq offset), reconciles row counts against the probe
report, and compresses to zstd.

Usage: jmdict_build.py <json_path> <names_json_path> <db_path> <zst_path>
                       <probe_log_path> <artifact_tag> <pin_sha256> <pin_asset>
                       <name_pin_tag> <name_pin_sha256> <name_pin_asset>
"""

import json
import os
import re
import sqlite3
import subprocess
import sys
import unicodedata

# JMnedict ingest scope: keep an entry when at least one of its types is
# outside this set; kept entries still record every type in pos.
NAME_EXCLUDED_TYPES = {"unclass", "place"}
NAME_SEQ_OFFSET = 10_000_000

# Sense glosses join with a control character that cannot occur inside an
# English gloss, so the app can split the column back into individual glosses
# without ambiguity. The historical joiner "; " occurs inside real glosses
# ("to scoop up (and remove; sand, earth, etc.)" is one gloss, not three),
# and splitting on it shredded them at every display site. The tripwires in
# both ingest loops fail the build rather than let a gloss carry the joiner
# silently. Mirrored by JMDictPin.glossJoiner; build_dictionary.sh pins both
# declarations against drift.
GLOSS_JOINER = "\x1f"


def nfkc(text):
    """One canonical form at the ingestion boundary. Every query side in the
    app NFKC-folds its probe (JMDictLookup.probeText,
    DictionarySearchEngine.normalize), so stored text must already be in that
    form or an equality seek can never hold (ＴＫＧ folds to TKG; stored raw
    ＴＫＧ would miss forever). Applies to headwords, entry writings, senses,
    and the per-sense restriction writings the lookup compares folded taps
    against.
    """
    return unicodedata.normalize("NFKC", text)


def open_word_stream(path):
    """Open a stream-format dictionary file: header keys, then '"words": ['.

    Returns (file handle, header dict, first-chunk remainder after '[').
    """
    header = {}
    first = ""
    f = open(path, encoding="utf-8-sig")
    for line in f:
        s = line.strip()
        if s.startswith('"words"'):
            first = s.split("[", 1)[1] if "[" in s else ""
            break
        m = re.match(r'"([A-Za-z]+)"\s*:\s*(.*?),?\s*$', s)
        if m:
            header[m.group(1)] = m.group(2).rstrip(",")
        elif s in ("{", "}"):
            continue
        else:
            f.close()
            print(f"ERROR: unrecognized header line in {path}: {s[:80]!r}", file=sys.stderr)
            sys.exit(1)
    return f, header, first


def main(json_path, names_json_path, db_path, zst_path, probe_log_path,
         artifact_tag, pin_sha256, pin_asset, name_pin_tag, name_pin_sha256, name_pin_asset):
    errors = []
    def fail(msg):
        errors.append(msg)

    def out(line=""):
        print(line)

    # --- headers -----------------------------------------------------------------
    # BOM stripped by utf-8-sig; header keys precede the "words": [ line. One file
    # handle per input: the word stream continues right after the "words" line.
    f, header, first = open_word_stream(json_path)

    version = header.get("version", "?").strip('"')
    dict_date = header.get("dictDate", "?").strip('"')

    # --- schema (plan §3 — no FTS, exact headwords.text queries only) ------------
    # headwords/senses are WITHOUT ROWID with the query path as PRIMARY KEY:
    # headwordRowsSQL's WHERE text = ? becomes the PK prefix seek and senseSQL's
    # WHERE entry_id = ? ORDER BY ord a prefix range scan with ordering built in,
    # so the secondary indexes are absorbed and dropped. Plain INSERT everywhere:
    # upstream has no duplicate (text, entry_id, kind) / (entry_id, ord) rows in
    # raw form, and the NFKC fold's merges are deduped at the row level below
    # (first spelling in source order wins), so a future duplicate still fails
    # the build loudly on the PK.
    conn = sqlite3.connect(db_path)
    conn.executescript("""
    PRAGMA journal_mode=OFF;
    PRAGMA synchronous=OFF;
    PRAGMA cache_size=-65536;
    CREATE TABLE entries(ent_seq INTEGER PRIMARY KEY, keb TEXT, reb TEXT, common INTEGER NOT NULL);
    CREATE TABLE senses(entry_id INTEGER NOT NULL REFERENCES entries(ent_seq),
      ord INTEGER NOT NULL, pos TEXT, gloss TEXT NOT NULL, misc TEXT, skeb TEXT, sreb TEXT,
      PRIMARY KEY(entry_id, ord)) WITHOUT ROWID;
    CREATE TABLE headwords(entry_id INTEGER NOT NULL REFERENCES entries(ent_seq),
      text TEXT NOT NULL, kind TEXT NOT NULL, jlpt INTEGER, hatsuon TEXT, acc TEXT, zo TEXT,
      PRIMARY KEY(text, entry_id, kind)) WITHOUT ROWID;
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
    """)

    # One word per line, trailing comma even on the last; the first word sits on
    # the "words": [ line itself. Not valid JSON as a whole — stream it.
    def word_chunks(fobj, first):
        if first.strip():
            yield first
        for raw in fobj:
            s = raw.strip()
            if s in ("]}", "]"):
                return
            if s:
                yield s

    def norm_restricted(lst):
        # "*" = applies to all writings -> NULL; otherwise JSON (empty list =
        # matches none — defensive, upstream never emits it at sense level).
        # The stored writings are what the lookup compares an NFKC-folded tap
        # against, so they fold onto the same canonical spellings the
        # headwords carry.
        if lst is None or lst == ["*"]:
            return None
        return json.dumps([nfkc(w) for w in lst], ensure_ascii=False)

    def hw_row(obj, kind):
        # Furigana is dropped (IPADIC-based alignment already exists).
        pa = obj.get("pitchAccent")
        if isinstance(pa, dict):
            pitch = (pa.get("hatsuon"), pa.get("accPatts"), pa.get("zoPatts"))
        else:
            pitch = (None, None, None)
        return (nfkc(obj["text"]), kind, obj.get("jlptLevel"), *pitch)

    def reading_for_keb(keb):
        # The reading a kanji writing's furigana names: the rt chunks
        # concatenate to kana text. Upstream omits rt when the reading equals
        # the ruby (jmdict_probe.py's furigana_no_rt contract) — okurigana
        # pieces — so those fall back to the ruby itself; kanji pieces always
        # carry rt. Missing/empty furigana yields None (nothing to join to).
        # Normalized so the kana_rows keys it reads are the same normalized
        # spellings hw_row stores (halfwidth-kana readings included).
        text = "".join(
            piece.get("rt") or piece.get("ruby") or ""
            for piece in keb.get("furigana") or []
        )
        if not text:
            return None
        return nfkc(text) or None

    def normalized_headword_rows(ent_seq, kobjs, robjs):
        # Bare-row backfill. JLPT rides individual kanji writings upstream but
        # reads as word-level in the card, so a writing with no jlptLevel
        # takes the word's first non-null level in source order (kanji
        # writings then kana). Pitch is per-reading, so it never crosses
        # readings: rows with their own accent keep it verbatim (the 飴
        # homograph keeps acc 0 on kanji vs acc 1 on あめ), a kanji row with
        # no accent inherits only from the kana row its furigana names (確 of
        # 確か takes たしか's), and a kana row with none stays NULL rather
        # than wear another reading's accent.
        writings = [(o, "keb") for o in kobjs] + [(o, "reb") for o in robjs]
        rows = [hw_row(obj, kind) for obj, kind in writings]
        kana_rows = {row[0]: row for (_, kind), row in zip(writings, rows)
                     if kind == "reb"}
        jlpt_fallback = next((row[2] for row in rows if row[2] is not None), None)
        enriched = []
        for (obj, kind), row in zip(writings, rows):
            text, _, jlpt, hatsuon, acc, zo = row
            if jlpt is None:
                jlpt = jlpt_fallback
            if kind == "keb" and hatsuon is None and acc is None and zo is None:
                kana_row = kana_rows.get(reading_for_keb(obj))
                if kana_row is not None:
                    hatsuon, acc, zo = kana_row[3:]
            enriched.append((ent_seq, text, kind, jlpt, hatsuon, acc, zo))
        # The NFKC fold can merge two of one entry's own writings (TKG and
        # ＴＫＧ both land on TKG) onto one PK key. First spelling in source
        # order wins — the same "first row wins" convention the lookup uses
        # for multiple headword rows of one entry — and the dropped count is
        # reported by the build summary.
        deduped = []
        seen = set()
        for row in enriched:
            key = (row[1], row[2])
            if key in seen:
                counts["headwords_deduped"] += 1
                continue
            seen.add(key)
            deduped.append(row)
        return deduped

    BATCH = 5000
    entries_batch, senses_batch, headwords_batch = [], [], []
    counts = {"entries": 0, "senses": 0, "headwords": 0,
              "headwords_raw": 0, "headwords_deduped": 0,
              "name_entries": 0, "name_headwords": 0,
              "name_headwords_raw": 0, "name_headwords_deduped": 0}
    name_max_seq = 0

    def flush():
        if entries_batch:
            conn.executemany("INSERT INTO entries VALUES (?,?,?,?)", entries_batch)
            entries_batch.clear()
        if senses_batch:
            conn.executemany("INSERT INTO senses VALUES (?,?,?,?,?,?,?)", senses_batch)
            senses_batch.clear()
        if headwords_batch:
            conn.executemany("INSERT INTO headwords VALUES (?,?,?,?,?,?,?)", headwords_batch)
            headwords_batch.clear()

    for stripped in word_chunks(f, first):
        if stripped.endswith(","):
            stripped = stripped[:-1]
        try:
            w = json.loads(stripped)
        except Exception as exc:
            fail(f"word JSON failed to parse: {exc}: {stripped[:120]!r}")
            break

        ent_seq = int(w["id"])
        kobjs = w.get("kanji") or []
        robjs = w.get("kana") or []
        common = 1 if any(o.get("common") for o in kobjs) or any(o.get("common") for o in robjs) else 0
        entries_batch.append((
            ent_seq,
            nfkc(kobjs[0]["text"]) if kobjs else None,
            nfkc(robjs[0]["text"]) if robjs else None,
            common,
        ))
        word_headword_rows = normalized_headword_rows(ent_seq, kobjs, robjs)
        headwords_batch.extend(word_headword_rows)
        for ord_i, s in enumerate(w.get("sense") or []):
            glosses = [nfkc(g["text"]) for g in (s.get("gloss") or []) if g.get("lang") == "eng"]
            if any(GLOSS_JOINER in gloss for gloss in glosses):
                fail(f"word {ent_seq}: a gloss contains the reserved gloss joiner")
            senses_batch.append((
                ent_seq,
                ord_i,
                nfkc(",".join(s.get("partOfSpeech") or [])) or None,
                GLOSS_JOINER.join(glosses),
                nfkc(", ".join(s.get("misc") or [])) or None,
                norm_restricted(s.get("appliesToKanji")),
                norm_restricted(s.get("appliesToKana")),
            ))
        counts["entries"] += 1
        counts["headwords_raw"] += len(kobjs) + len(robjs)
        counts["headwords"] += len(word_headword_rows)
        counts["senses"] += len(w.get("sense") or [])
        if len(entries_batch) >= BATCH:
            flush()
    f.close()

    # --- JMnedict names — same tables, +10M ent_seq offset -----------------------
    # Names layout: one entry per line, every line comma-terminated except the
    # last, which carries the array-closing "]" glued on after the entry's
    # "}" ("...}]"), then a final "}" line.
    nf, name_header, name_first = open_word_stream(names_json_path)
    name_version = name_header.get("version", "?").strip('"')
    name_dict_date = name_header.get("dictDate", "?").strip('"')

    def name_chunks(fobj, first):
        # The first chunk (remainder after the '"words": [' line) gets the
        # same trailing-comma / glued-']' treatment as every later line, so
        # an upstream layout change cannot smuggle a raw chunk through.
        s = first.strip()
        if s:
            if s in ("}", "]"):
                return
            if s.endswith("}]"):
                yield s[:-1]
                return
            if s.endswith(","):
                s = s[:-1]
            if s:
                yield s
        for raw in fobj:
            s = raw.strip()
            if not s:
                continue
            if s in ("}", "]"):
                return
            if s.endswith("}]"):
                yield s[:-1]
                return
            if s.endswith(","):
                s = s[:-1]
            if s:
                yield s

    for stripped in name_chunks(nf, name_first):
        if not (stripped.startswith("{") and stripped.endswith("}")):
            fail(f"names entry not a single object: {stripped[:120]!r}")
            break
        try:
            w = json.loads(stripped)
        except Exception as exc:
            fail(f"names entry JSON failed to parse: {exc}: {stripped[:120]!r}")
            break

        # First-occurrence-deduped types across all translation[] objects; a
        # kept entry records every type (e.g. place,surname), never just the
        # one that kept it. English glosses only, mirroring the JMDict path
        # (the probe hard-fails on any non-eng gloss first).
        try:
            types = []
            glosses = []
            seen = set()
            for t in w.get("translation") or []:
                for v in t.get("type") or []:
                    if v not in seen:
                        seen.add(v)
                        types.append(v)
                for g in t.get("translation") or []:
                    if g.get("lang") == "eng":
                        glosses.append(g.get("text") or "")
            if all(v in NAME_EXCLUDED_TYPES for v in types):
                continue

            ent_seq = int(w["id"]) + NAME_SEQ_OFFSET
            if any(GLOSS_JOINER in gloss for gloss in glosses):
                fail(f"name {w.get('id')}: a gloss contains the reserved gloss joiner")
        except (AttributeError, KeyError, TypeError, ValueError) as exc:
            fail(f"names entry has an unexpected shape: {exc}: {stripped[:120]!r}")
            break
        kobjs = w.get("kanji") or []
        robjs = w.get("kana") or []
        # JMnedict has no common marking at all: names always rank below
        # common JMDict entries.
        entries_batch.append((
            ent_seq,
            nfkc(kobjs[0]["text"]) if kobjs else None,
            nfkc(robjs[0]["text"]) if robjs else None,
            0,
        ))
        # Same normalized + per-entry dedupe as the words path: one name can
        # carry two writings that fold onto one spelling, and the PK is
        # (text, entry_id, kind).
        name_seen = set()
        for o in kobjs:
            text = nfkc(o["text"])
            if (text, "keb") in name_seen:
                counts["name_headwords_deduped"] += 1
                continue
            name_seen.add((text, "keb"))
            headwords_batch.append((ent_seq, text, "keb", None, None, None, None))
        for o in robjs:
            text = nfkc(o["text"])
            if (text, "reb") in name_seen:
                counts["name_headwords_deduped"] += 1
                continue
            name_seen.add((text, "reb"))
            headwords_batch.append((ent_seq, text, "reb", None, None, None, None))
        # One sense per entry; glosses flatten across every translation[]
        # object in order. No restriction filtering applies (misc/skeb/sreb
        # NULL = applies to every writing).
        senses_batch.append((
            ent_seq,
            0,
            nfkc(",".join(types)) or None,
            GLOSS_JOINER.join(nfkc(g) for g in glosses),
            None,
            None,
            None,
        ))
        counts["name_entries"] += 1
        counts["name_headwords_raw"] += len(kobjs) + len(robjs)
        counts["name_headwords"] += len(name_seen)
        if ent_seq > name_max_seq:
            name_max_seq = ent_seq
        if len(entries_batch) >= BATCH:
            flush()
    nf.close()

    flush()

    # --- reconcile against the probe report (same pins, same files) --------------
    if not os.path.exists(probe_log_path):
        fail(f"probe report missing: {probe_log_path} (run the probe first)")
    else:
        probe = open(probe_log_path, encoding="utf-8").read()
        def probe_count(pattern):
            m = re.search(pattern, probe, re.M)
            if not m:
                fail(f"probe report missing stat {pattern!r}")
                return None
            return int(m.group(1))
        expected = {
            # Raw object counts: parse fidelity — the build saw exactly the
            # writings the probe counted.
            "entries": (probe_count(r"^entries: (\d+)$"), counts["entries"]),
            "headwords (raw)": (probe_count(r"^headword rows \(kanji\[\]\+kana\[\] objects\): (\d+)"),
                                counts["headwords_raw"]),
            "senses": (probe_count(r"^senses: (\d+)"), counts["senses"]),
            "name entries": (probe_count(r"^name entries: (\d+)$"), counts["name_entries"]),
            "name headwords (raw)": (probe_count(r"^name headword rows \(kanji\+kana objects\): (\d+)"),
                                     counts["name_headwords_raw"]),
            # Normalized counts: what the probe predicts the build inserts
            # after the NFKC fold's per-entry merges — the number that must
            # equal the DB's headword rows.
            "headwords": (probe_count(r"^headword rows \(normalized\): (\d+)"),
                          counts["headwords"]),
            "name headwords": (probe_count(r"^name headword rows \(normalized\): (\d+)"),
                               counts["name_headwords"]),
        }
        for label, (want, got) in expected.items():
            if want is not None and got != want:
                fail(f"{label} mismatch: DB {got} vs probe {want}")
        probe_name_id_max = probe_count(r"^name id max: (\d+)$")
        if probe_name_id_max is not None and name_max_seq != probe_name_id_max + NAME_SEQ_OFFSET:
            fail(f"name id max mismatch: DB {name_max_seq} vs probe {probe_name_id_max} "
                 f"(+{NAME_SEQ_OFFSET} offset)")

    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    # --- meta -------------------------------------------------------------------
    conn.executemany("INSERT OR REPLACE INTO meta VALUES (?,?)", [
        ("version", version),
        ("tag", artifact_tag),
        ("digest", pin_sha256),
        ("source_asset", pin_asset),
        ("dict_date", dict_date),
        ("names.tag", name_pin_tag),
        ("names.digest", name_pin_sha256),
        ("names.source_asset", name_pin_asset),
        ("names.version", name_version),
        ("names.dict_date", name_dict_date),
        ("names.entries", str(counts["name_entries"])),
        ("entries", str(counts["entries"])),
        ("senses", str(counts["senses"])),
        ("headwords", str(counts["headwords"])),
    ])
    conn.commit()
    # Compacts the b-trees after the streamed inserts; sizes below are
    # measured over the whole DB post-VACUUM.
    conn.execute("VACUUM")

    def compress():
        subprocess.run(["zstd", "--ultra", "-22", "-f", "-q", "-o", zst_path, db_path], check=True)
        return os.path.getsize(zst_path)

    zst_bytes = compress()
    # Record both sizes, then recompress once so the shipped zst matches the
    # final DB bytes (the recorded values are the pre-close measurements).
    conn.executemany("INSERT OR REPLACE INTO meta VALUES (?,?)", [
        ("size.sqlite.bytes", str(os.path.getsize(db_path))),
        ("size.zst.bytes", str(zst_bytes)),
    ])
    conn.commit()
    conn.close()
    compress()

    raw_mb = os.path.getsize(db_path) / (1000 * 1000)
    zst_mb = os.path.getsize(zst_path) / (1000 * 1000)
    out("==> JMDict DB built")
    out(f"    db:      {zst_path} ({zst_mb:.1f} MB; uncompressed {raw_mb:.1f} MB)")
    out(f"    rows:    entries {counts['entries']} / headwords {counts['headwords']} / "
        f"senses {counts['senses']} (reconciled with probe; "
        f"NFKC merged {counts['headwords_deduped']} writings)")
    out(f"    names:   entries {counts['name_entries']} / headwords {counts['name_headwords']} "
        f"(ent_seq >= {NAME_SEQ_OFFSET}; NFKC merged {counts['name_headwords_deduped']})")
    out(f"    meta:    version={version} dictDate={dict_date} tag={artifact_tag} "
        f"names.version={name_version} names.dictDate={name_dict_date} names.tag={name_pin_tag}")
    out(f"    DMG delta: ~{zst_mb:.1f} MB")


if __name__ == "__main__":
    if len(sys.argv) != 12:
        print("usage: jmdict_build.py <json_path> <names_json_path> <db_path> <zst_path> "
              "<probe_log_path> <artifact_tag> <pin_sha256> <pin_asset> "
              "<name_pin_tag> <name_pin_sha256> <name_pin_asset>", file=sys.stderr)
        sys.exit(2)
    main(*sys.argv[1:12])
