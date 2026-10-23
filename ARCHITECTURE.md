# Architecture

**Mimidasu** — a real-time Japanese livestream transcriber/translator for
macOS (Apple Silicon, 15.5+). Captures system audio via a Core Audio process
tap, streams it through a selectable ASR GGUF — **Lite** (SenseVoice-Small,
default) or **Full** (FunASR-Nano) — via the CrispASR runtime with
FireRedVAD endpointing, and translates finalized sentences to a selectable
target language (English by default) with Apple's on-device Translation
framework — or Apple Intelligence where installed — or an optional cloud
provider (Google Translate, DeepL, OpenRouter) behind the same provider
seam (`TranslationEngine`). Ruby
annotations (romaji/furigana) and tap-to-lookup dictionary entries come
from a bundled IPADIC tokenizer plus a pinned JMDict/JMnedict SQLite DB,
which also powers a full-dictionary search (Japanese / romaji / English
gloss) in a two-mode reference window. Starred words persist to a
searchable Favorites store and render highlighted wherever Japanese text is
shown. Finalized sentences and their translations also persist to a local
SQLite **session archive** (Recent/Saved, multi-language re-translation)
that can be reopened, exported, and browsed without re-running capture, and
a live session can be paused and resumed without tearing down the capture
rig.

## System overview

```
             system audio (whole mix minus Mimidasu)
                            │
                            ▼
             ┌─────────────────────────────┐
             │      SystemAudioCapture     │ Core Audio process tap;
             │  f32 mono 16 kHz, 160 ms    │ private aggregate device
             └──────────────┬──────────────┘
                            ▼
             ┌─────────────────────────────┐
             │        CrispASREngine       │ libcrispasr.dylib (dlopen);
             │  partials + endpoint finals │ FireRedVAD endpointing
             └──────────────┬──────────────┘
                            ▼
             ┌─────────────────────────────┐
             │        SentenceBuffer       │ 3-tier boundaries; session
             │                             │ sample-clock timestamps
             └──────────────┬──────────────┘
                            ▼
             ┌─────────────────────────────┐
             │       TranslationQueue      │ ja→target (EN default);
             │                             │ Apple on-device or cloud,
             │                             │ serialized
             └──────────────┬──────────────┘
                            ▼
             ┌─────────────────────────────┐
             │      AppModel (UI state)    │ transcript, live partial,
             │        (@MainActor)         │ translations, meters, toasts
             └─────────────────────────────┘
```

Sidecars off the main flow:

- **ModelLocator / ModelVerifier / ModelDownloader** — resolve, SHA-256
  verify, and download the chosen GGUF.
- **ReadingAnnotator + DictionaryStore + JMDictLookup** — ruby annotation
  and tap-to-lookup over the tokenizer and dictionary DBs.
- **DictionarySearchEngine (+ FTS5 gloss index)** — full-dictionary search
  behind the reference window's Dictionary mode: a staged candidate ladder
  over the same prepared DB (exact / prefix / lemma-retry / gloss), with
  scope, Match kind, JLPT, POS, and name-type filters.
- **FavoritesStore / FavoritesDatabase / FavoriteIdentity /
  FavoritesPromotion** — starred words: SQLite persistence, one identity
  value behind star/highlight/promotion, transcript highlight matching,
  Favorite-first lookup ranking.
- **RetranslateCoordinator + the re-translate lane** — manual
  re-translate of a finalized Sentence through a selected provider
  (dedicated Apple sessions, serialized lane, provenance stamps).
- **ArchiveStore / ArchiveReadModel / ArchiveTranslationJob** — every
  finalized sentence and landed translation persists to `archives.sqlite`;
  Recent/Saved browsing, interrupted-session sweep, bulk multi-language
  re-translation, and archive-aware export.
- **SessionExporter** — TXT / SRT / VTT / JSON.
- **ToastCenter / NoticeCenter** — every error/status surface.

Native runtime: `crispasr/` (`libcrispasr.dylib` + ggml companions +
`firered-vad.gguf`) and `libdictionary.dylib` — dlopen'd, so the app builds
and launches before they exist (ASR then runs as a clearly-labeled mock
driven by real audio). Dev checkouts keep them in `local/frameworks/`;
packaged apps in `Contents/Frameworks/`.

## Components

### SystemAudioCapture (`Audio/`)
- Core Audio process tap (macOS 15+): a global `CATapDescription` excluding
  Mimidasu's own process (`muteBehavior = .unmuted`, so playback is never
  muted), attached as the sole input of a private aggregate device; an IO
  block on a dedicated queue receives each cycle's PCM.
- Downmix to mono, resample to 16 kHz (`AVAudioConverter`), slice fixed
  160 ms chunks (2,560 samples). Whole-system mix — no app picker, no PID
  tracking.
- Pause/resume: `pause()` stops the tracked IOProc without rebuilding the
  tap or aggregate, clears the sample accumulator, and raises an `isPaused`
  fence that drops racing callbacks; `resume()` restarts the same IOProc and
  clears the fence only on success (a failed resume leaves capture paused).
  Teardown is idempotent for a paused rig.
- Permission: system-audio recording (TCC, separate from Microphone). The
  prompt fires on the aggregate's first IO; a refusal surfaces a pointer to
  System Settings.
- Failure: device death / tap removal listeners emit `.captureLost`
  (Restart capture toast); unreadable formats emit `.formatUnavailable`; output
  rate changes rebuild the converter live. `AudioCaptureHAL` owns the tap /
  aggregate / IOProc IDs and property listeners behind single-claim
  teardown (so `stop`, `deinit`, and dead-device paths can't
  double-destroy); `ProcessTapFactory` builds the tap + aggregate pair;
  `AudioLevels` shares the RMS math and the −60 dBFS silence floor used by
  the no-audio watchdog (the engine's RMS backstop carries its own
  equal-valued constant).

### CrispASREngine (`ASR/`)
- Swift wrapper over dlopen'd `libcrispasr.dylib` (stable C session ABI;
  vendored headers in `native/include/crispasr/`). The backend
  (`sensevoice` / `funasr`) is detected from the GGUF header — a property
  of the chosen model, not the build — with a filename fallback when the
  detection symbol is missing or unparsable.
- The backends have no cache-aware streaming, so the sliding window lives
  in Swift: a rolling utterance buffer (12 s forced-final cap) plus a 10 s
  window for partial decodes.
- **FireRedVAD** is dispatched on its own queue every 500 ms of *new*
  audio (push-gated, not timer-driven) and is the authoritative speech
  signal. Each pass re-analyzes the whole utterance and its latest span end
  replaces earlier ones. It gates partial decodes, and 1.0 s of analyzed
  audio past the last VAD speech span end finalizes the utterance (the VAD's
  own internal span-closing silence is 800 ms). Speechless buffers shorter
  than 2 s are kept for onset detection; longer ones are discarded without
  decoding. A cheap per-chunk RMS check is only a backstop (and covers
  degraded mode when the VAD model is unavailable).
- 1 s-step window decodes post `.partial` (HUD draft), gated on
  VAD-confirmed speech and a newer VAD speech end; a window decode is
  skipped while a final decode is airborne, and empty text posts nothing.
  The endpoint redecodes the buffered utterance PCM and posts one clean
  `.final`; an empty/failed final still closes the utterance without an
  event.
- Lifecycle: `dlopen` is process-cached, while each engine init calls
  `CrispASRLibrary.open()` and rebinds the symbol set. `prepare` reuses a
  warm open session and skips the GGUF reload → `openStream` → `push` per
  chunk → `poll` from a 60 ms timer → `finish` (drain + final flush; the
  session **stays warm**). `flushUtterance` is the non-latching pause
  variant: it drains, decodes the open utterance, closes it, and resumes
  cleanly. `close()` runs only when the factory retires the engine (model
  swap or quit), never on session stop. Decodes run on a dedicated serial
  queue so `poll` never blocks behind a multi-second decode; session
  teardown is capture stop → channel finish/drain (consuming any airborne
  pause flush) → timers → buffer flush → translation drain.
- `ASREngine` protocol + factory: CrispASR when the runtime and model
  resolve, otherwise the labeled mock transcriber (finals only, RMS-gated,
  randomized speech cadence). The factory holds a path-keyed warm-engine
  cache, a `retired` latch, and a runtime-poison latch for a leaked
  `close()`; a quit-time shutdown frees the VAD cache.

### SentenceBuffer (`Session/`)
- Streaming ja ASR routinely drops punctuation, so boundaries are 3-tier:
  1. Terminal punctuation (`。！？` plus ASCII `!`/`?`) closes immediately.
  2. No new finals for ~1 s finalizes the buffer.
  3. 42-char split trigger, split at the first clause boundary found
     at/after 18 chars, scanning the fixed priority `けど` / `から` / `ので` /
     `って` / `、` / `,`. Without a clause boundary the buffer keeps growing,
     so this is not a hard cap.
  Symbol-only finals (e.g. `...`) never start a sentence.
- **Final gate:** only Japanese-script finals become sentences —
  `KanaClassification.containsJapanese`, kana included, because the final
  re-decode often renders kanji words as kana even when the partial showed
  kanji. Latin/symbol-only finals are dropped at the door and recorded via
  `noteTrailing`: speech continued, so the open sentence's silence timer
  and end span stay honest without appending anything.
- Timestamps from the session sample clock (chunk offsets ÷ 16 kHz): each
  sentence records `start_s`/`end_s`, ±160 ms granularity. Partials are
  never stamped.
- Output: immutable `Sentence` `{index, startS, endS, lang, text}` (JSON
  keys `start_s` / `end_s` / `transcript`) published to UI state and queued
  for translation.

### Translation (`Translation/`)
- **Seam:** `TranslationEngine` — ordered batch `translate`, `preferredBatchSize`,
  optional `onRetry`, a `transientBadResponse` flag (do malformed replies
  deserve a retry?), typed error taxonomy. `TranslationQueue.run(with:)`
  accepts any provider; `Translation/Providers/` holds the cloud adapters.
- **Coordination:** `TranslationSessionCoordinator` owns the live
  attach/retry/fallback/provider machinery; `AppleTierAvailability` owns the
  pair-scoped Apple Intelligence evidence/token/strategy resolution shared
  with the lane; `RetranslateCoordinator` owns the lane. `AppModel` keeps phase,
  entries, archive state, and toasts and forwards through façade extensions
  over `TranslationSessionPort` (`phase` · `toasts` · `applyTranslation` ·
  archive session/viewing language/running flag · `beginArchiveTranslation`).
- **Providers:** Apple on-device (`AppleSessionEngine` fed by SwiftUI's
  `.translationTask`, hosted in a process-lifetime 1×1 panel
  (`TranslationSessionPanelController`) so closing the main window can't
  cancel the task and strand the queue's pending sentences; the default;
  OS prompts a one-time language pack), and Google Translate, DeepL,
  OpenRouter. On macOS 26.4+ the live session config requests the Apple
  Intelligence strategy, with silent framework fallback to Apple (NMT).
  `AppleTierAvailability` records pair-scoped evidence
  `(installed, targetCode)` behind a sequence token; the probe
  fires on Apple and external activation and on fallback, and a session end
  supersedes an airborne landing. Unknown pairs stay offered, but only an
  installed pair is labelled/available as "Apple Intelligence"; target-scoped
  `effectiveTier` degrades a known-missing pair to Apple (NMT). The same
  panel hosts two more lazily-armed `.translationTask` hosts dedicated to
  the re-translate lane (Apple (NMT) and Apple Intelligence), stacked in
  one view tree because multiple modifiers on one view are unreliable.
- **Cloud adapters:** Google Translate (batch REST), DeepL (batch REST,
  `:fx` free-tier host), OpenRouter (chat completions, **one sentence per
  request** with a plain-text prompt parsed leniently — no JSON contract —
  and a default model when Settings leaves the field empty). Source is
  fixed `ja`; the target follows the selection. Provider switching is
  live: a verified selection re-attaches the provider mid-session (pending
  sentences replay via the queue's generation token; the Apple-fallback
  latch resets — an explicit change is user intent to re-engage), and a
  key save's connection test re-attaches an already-selected provider once
  it verifies (a fresh switch still completes through the disclosure
  sheet).
- **Target language:** `TargetLanguage` carries a BCP-47 entry code plus
  per-provider mappings (Google/DeepL API codes; OpenRouter prompts name the
  language); the selection persists as `translation.targetLanguage` and is
  restart-only — the picker disables while a session is `.starting`,
  `.running`, `.paused`, `.stopping`, or `.sourceLost`.
  `AppleTranslationAvailability` normalizes `LanguageAvailability.supportedLanguages`
  (drops `ja`, collapses regional variants, drops unknown codes, dedupes,
  sorts by localized name); the static metadata table supplies the English
  name and per-provider codes, while display/native names are computed. A
  persisted code with no entry falls back to English on load. A
  non-English pick confirms `DictionaryEnglishNoticeSheet` first (word
  lookups stay English-glossed; re-raised on every non-English pick).
- **Queue:** strictly serialized `@MainActor` worker; untranslated
  sentences live in a plain array that survives cancellation; a generation
  token plus a session-epoch token retire cancelled runs and batches
  airborne across a session boundary; repeats are served from an
  app-run-scoped NSCache (200 entries); empty finals dropped at enqueue;
  in-flight IDs guard against double translation; a batch retired at the
  session boundary drops its results and publishes no `.ready`. On stop
  the queue drains with a 5 s bound so the session stays exportable.
- **Retry ladder:** transient failures (429 / 5xx / network) retry twice
  with backoff, honoring a capped `Retry-After`; invalid key, quota, and
  malformed output fail fast — except chat-completions providers, which
  retry malformed output (nondeterministic LLM replies) while fixed-
  contract Google/DeepL never do. Settings' Test probes run zero-retry
  (Google/DeepL translate a probe sentence; OpenRouter validates the key
  via a key endpoint so no tokens are spent), and the outcome persists per
  provider.
- **Failure ladder:** exhausted external errors latch Apple on-device for
  the rest of the session (one-way per session; `.degraded` published; the
  manual Reconnect action re-attempts the external provider and resets the
  latch). Apple itself failing publishes `.unavailable` with **no** provider
  swap — Reconnect is the only way back. A selected-but-unconfigured
  provider (key deleted) degrades to Apple at activation — no toast; the
  sidebar ENGINES card and Settings' "Currently using" row surface the
  state.
- **Keys:** `KeychainStore` (`Security/`, device-only accessibility);
  key material never reaches UserDefaults, logs, error strings, or export
  files — the settings store persists non-secrets only (provider
  selection, key-presence flags + hints, test outcomes, the OpenRouter
  model, DeepL free-tier). Dev builds pin the key store to a no-op, so
  development always runs Apple on-device.
- **Disclosure:** activating any cloud provider — for the live session, the
  re-translate lane, or a bulk archive run — requires confirming
  `CloudDisclosureSheet` with intent-aware copy ("sentences transcribed from
  your Mac's audio will be sent to \<provider\>" for a switch; only
  explicitly re-translated lines for the lane; the selected sentence count
  for a bulk run). `PendingCloudDisclosure` carries all three intents,
  raised on every switch to an external provider; audio itself never leaves
  the machine.
- **Re-translate lane:** a finalized Sentence can be re-translated through
  a selected provider (`session` / `appleFast` / `appleHighFidelity` /
  `google` / `deepl` / `openrouter`, persisted as
  `translation.retranslateEngine`). Routes resolve at click time against
  the *lane target*: Settings' target for a live session, the open
  archive's viewing language for an archived Sentence. A live `.session`
  selection, an external selection equal to the attached provider, and an
  Apple selection the landed probe proves equal to the Session engine all route
  through the queue unstamped; everything else runs through a serialized
  lane of chained tasks with dedicated, lazily-armed Apple sessions
  (explicit `preferredStrategy`, so a lane can't silently duplicate the
  Session engine), Apple lanes deferring behind the availability probe's landing in
  live mode. Archive mode never uses the queue: `.session` maps to
  Apple (NMT), every re-translate is a dedicated alternate, and the probe
  gate is skipped. Dispatching drops any queued copy; landings stamp the
  SessionEntry's `engine` provenance, and seed the repeat cache only when
  the SessionEntry accepted the result (live only).
  Apple Intelligence picks degrade to Apple (NMT) below macOS 26.4 or where
  the pair-scoped strategy is known unavailable; delivery is
  session-epoch-guarded (archive open/close bumps the epoch) and phase- or
  archive-open-guarded so a stale lane can't write into a new session;
  failures post yellow toasts.
- **Status surface:** `TranslationPill.map(status:activeEngine:fallbackActive:)`
  is a pure tone mapping (a latched `.ready` reads yellow); the sidebar
  ENGINES card's provider row consumes its `tone` (there is no separate
  pill view). The sidebar titles the attached provider
  (`SidebarStatus.translationEngineName` — "Apple Intelligence" when the
  Apple Intelligence pair is installed, else "Apple", or the provider) over a
  detail line mirroring state ("On-device (fallback)", "Unavailable",
  "External"); Settings repeats it in its "Currently using" row.
  Retry/fallback/unavailable states surface as toasts.

### Reading annotation & dictionary lookup (`Text/`, `Dictionary/`)
- **Annotator:** `ReadingAnnotator` tokenizes via `DictionaryEngine`
  (dlopen'd `libdictionary.dylib`, bundled IPADIC) and emits segments
  `{surface, romaji, furigana, lemma, pos, isBound}` — one segmentation
  feeds both annotation modes and the Favorite matcher. The tokenizer
  payload carries `{text, start, end, reading, base, pos, bound}`; the
  runtime auto-detects the lexicon's feature scheme (bundled IPADIC;
  UniDic rows read with their pronunciation-style `ー` expanded), and
  `bound` marks non-self-standing words — 助動詞 outright, the 非自立
  detail rows, and 形容詞 rows lemmatizing to ない. Before segmentation,
  a run the tokenizer collapsed into one unknown node is re-decoded in
  short windows to recover the word boundaries inside it. Romaji derives
  from kana readings (Hepburn consonants, wapuro long vowels) with
  particle overrides (は/へ/を → wa/e/o), lexical spellings,
  numeral→counter fusion (`600回` → "roppyakkai"), and sokuon-span
  merging (`言って` → one segment). Furigana covers only kanji, aligned by
  walking the kana reading through the surface; tokens carry a curated
  reading per inflected surface, so conjugated forms annotate without
  re-inflection. A token-repair pass then a final fragmentation pass
  (threshold 8 chars: long enough, Japanese, whole surface missing from
  the dictionary) recover dictionary-backed pieces — sokuon-merged
  segments cut at their original token seams; the repair pass never
  consults the headword gate, probes that failed on infrastructure answer
  "has entry", and a pass that ran with the gate unreachable is not pinned
  in the segment cache (normal renders are).
- **Reading fallback:** kanji surfaces the tokenizer leaves reading-less
  consult JMDict's reading index, behind a miss-caching NSCache. Surfaces
  that survive both (names, rare ideographs, bare Latin) render
  self-transcribed and unannotated.
- **Fail-soft / readiness:** text rendering and lookups fail soft when an
  artifact is missing, but starting a session awaits
  `ensureDictionaryReady` — both databases must be adopted or built, and a
  failed build fails the start visibly (pressing Start retries). Launch
  also kicks both prepares opportunistically.
- **Lookup data:** pinned JMDict_Extended (`1.4.1-auto-release-2026-09-01`)
  + JMnedict (`3.6.2+20260914172325`), build revision 7. The pins live in
  `Dictionary/JMDictPin.swift` and are asserted by
  `scripts/build_dictionary.sh`, whose format probe hard-fails on upstream
  drift. Both sources build into one `jmdict-<tag>.<rev>.sqlite`
  (entries/senses/headwords/meta); JMnedict names ride `ent_seq + 10M` in
  the same tables. Names whose types are all `unclass`/`place` are dropped;
  kept names carry every type badge, one sense, and no JLPT/pitch data.
  Sense glosses are stored joined with `U+001F` so display-side splitting
  can't shred glosses containing `"; "`, and the artifact bundles a
  partial case-headword index (`headwords` rows whose ASCII text differs
  from `lower(text)`, plus a non-ASCII primary-key range scan at load — the
  case-spelling rescue for search). The DB bundles as
  `jmdict-<tag>.<rev>.sqlite.zst` — the tag + build revision is the
  staleness key, stale prepared artifacts are swept. Both DBs prepare under
  Application Support on first launch (DEBUG checkouts resolve/promote
  `build/prepared/dictionaries` instead), where preparation additionally
  derives a contentless
  **FTS5 trigram index over glosses** (rowid-packed by entry, promoted
  only after a smoke probe) — derived, never bundled; a debug-only
  `jmdict-<tag>.<rev>.dev.sqlite` (the build script's index-carrying
  intermediate in `build/`, which debug checkouts and the live tests
  resolve) sits outside the prepared directory and so is never swept.
- **Tap-lookup engine:** `JMDictLookup` — typed errors (a No hit is
  distinct from infrastructure failure; a headword row whose entry is missing reports
  `databaseCorrupt`), homograph entries ranked by four keys (tapped
  writing match, segment-reading match, common, `ent_seq`), sense
  restriction filters honored, NFKC folding at every SQL boundary.
  `JMDictExpansion` builds ≤9 ranked candidates per tap — the tapped
  surface, its lemma, a potential/passive unwrap (`作れる`/`作られる` → 作る,
  `される` → する), forward joins of up to 6 segments, then ≤3-char
  kanji-run splits run twice (over the tapped word and over the joined
  expansion text, so boundary-crossing words like 風呂+敷 → 呂敷 resolve) —
  resolved in that order, validated against the sentence's render text
  (drift fails closed: an un-re-anchorable tap becomes a No hit with no
  tapped query). A Join hit may
  lead the card (literal JOINED MATCH badge); a split-only tap resolves as a
  Bare miss with the Split hits demoted to Related pills — a Split never
  presents itself as the tapped word.
- **Display module:** `LookupDisplay` (resolve → promote → pager math) is
  a `Sendable` final class holding a `JMDictLookup` and running async
  detached queries beside `TapLookupRequest` / `TapLookupEffect` /
  `TapLookupFault`. `AppModelLookup` wires effects to state, toasts, and
  notices, but also re-resolves segments, snapshots `FavoriteIdentity`, and
  owns the generation guard. Sense rows map stored POS tags through the
  name-type label vocabulary and dedupe equal labels (stored order), and
  the pinned card stacks a multi-tag sense's tags above its gloss.
- **Tap interaction:** cursor modes None / Dictionary / Copy. A tap resolves
  through the pipeline and pins the Pinned card in the sidebar plus a
  popover anchored at the word; homograph entries walk via the `◀ i/N ▶` pager,
  Also hits surface as capped (9) "also:" pills (a forward-Join *Display*
  lead wears the JOINED MATCH badge; split-only taps show "related:" pills),
  pills are selectable and re-pin their chosen Entry as the Display (origin
  reset to the tapped word, `FavoritesPromotion` re-applied), a No hit
  posts the amber notice pill, and an infrastructure failure posts a toast.
  Name entries
  render type badges (SURNAME / GIVEN NAME / PLACE NAME / …) and drop the
  romanization-echo gloss. Favorite entries lead every pager via
  `FavoritesPromotion` (below).

### Dictionary search (`Dictionary/`, reference window)
- **Engine:** `DictionarySearchEngine` — a second read-only handle over
  the same prepared DB. Each query climbs a staged ladder, stopping when
  the result window saturates: exact PK seeks → bounded prefix B-tree
  range scans (20,000-row scan ceiling, 8,000 survivors kept for ranking,
  cancel-checked; the window itself pages 50 at a time to a 1,000-row
  ceiling) → a **lemma retry** (an unfiltered search runs it only when the
  headword stages came back empty; entry-level filters run it regardless,
  still requiring the exact Match kind and excluding name rows, since
  pre-join emptiness proves nothing: probe the Lemma first, then
  the potential unwrap, exact hits only — with a **romaji bridge** that
  converts a fully-consumed spelling (`tabetai`) to たべたい and
  lemmatizes the result) → a
  **gloss stage** over the FTS5 trigram index (Latin queries ≥3 chars,
  scope-filtered in SQL via rowid bounds). Candidate construction covers
  kana/katakana mirrors, fully-consumed romaji conversions plus
  trailing-onset expansion (`mak` → まか…まこ), literal digit/Latin
  spellings, script-switch prefixes, and the bundled case index
  (`activex` → ActiveX). Gloss hits grade into word-boundary / prefix /
  substring tiers with the matched gloss leading the preview. Window
  saturation skips stages that couldn't surface; exact totals re-run
  unbounded when a filter needs them. Ranking: tier → common →
  base-before-unwrap → matched length → `ent_seq`; unwrap rows drop when
  their base survives.
- **Filters:** scope (All / Words / Names), COMMON-only, Match kinds
  (exact / prefix / gloss — the last enabled can't be switched off), JLPT
  N1–N5, 11 rule-based POS groups, and 22 name-type badges. JLPT and POS
  are mutually exclusive with name types under All; every effective
  filter press re-runs the search against the debounced query and
  re-pages to page 1 (a no-op press writes nothing and re-runs nothing).
  All filter writes go through the pure `DictionaryFilterTransition` —
  `DictionarySearchState.apply(_:)` is the single funnel, and the
  transition owns the scope carry-over, the All-scope exclusions, the
  Match kind floor, and the COMMON-under-Names canonicalization.
- **Reference window:** one fixed 460×775.6 window (`Window("Dictionary")`)
  with two persisted modes — **Dictionary** (default) and **Favorites** —
  flipped by a header button, one shared 150 ms search debounce, focus
  hand-off between the modes' fields, a `displayed / matched(+)` count in
  Dictionary mode (Favorites shows `N / 8192` or `N entries`), and
  close-time state reset for both modes. Opened from the floating
  book opener over the transcript or the pinned card's kicker.
  Hits render as Favorite-style cards (Match kind chip first, then
  COMMON / JLPT / name-type badges, scalar-offset match highlight, 2-line
  gloss preview, copy → star → chevron) that expand in place into the
  shared entry view with a per-row pager; expansion is keyed by entry
  (`String(entSeq)`), so homograph rows sharing a headword expand
  independently, and an untouched row opens on its own entry rather than
  the lookup's ranked first. A starred entry written or read as the row's
  word is promoted to lead the expanded pager (`FavoritesPromotion` —
  reorder only, count unchanged), and the pager steps to absolute entry
  indexes. Each mode runs its own
  lookup handle, so a slow row expansion can't stall a tap or the other
  mode. Load-more reveals pages up to the 1,000-row ceiling ("Showing top
  N — refine your search"). The window stays up until explicitly closed —
  it does not dismiss on outside clicks.

### Favorites (`Favorites/`)
- **Star surface:** the dictionary popover, the pinned card, the search
  surface, and the Favorites mode list all mount one
  `DictionaryFavoriteButton` (the pill star is the separate lead probe),
  keyed by the displayed Entry's headword (non-empty `keb`, else `reb`)
  — homographs share one star and one list row. Starring twice is
  idempotent; un-starring never happens silently — the press raises
  `FavoriteRemovalConfirmation`, one alert per window: the main window
  owns the question for the popover + pinned card, the reference window
  owns one for its search and Favorite rows, and a `.popover` never
  presents the alert. A Bare miss carries no star; an `also:` pill
  stars only through its promoted lead Entry (the Bare-miss host passes no
  Favorites probe).
- **Model + persistence:** `FavoriteWord`
  `{headword, reading, romaji, addedAt}` in
  `~/Library/Application Support/Mimidasu/favorites.sqlite` — authored user
  data, so it lives there in every configuration. `headword` is the primary
  key (`INSERT OR IGNORE`, so re-starring is a no-op; un-starring deletes
  every stored spelling whose normalized form matches — membership is
  probed normalized, rows are deleted as stored); rows order by
  epoch-millisecond `addedAt`, newest first (headword breaks ties). A hard
  cap of 8,192 rows refuses the next star with a visible notice — nothing
  is ever silently evicted. One `FavoriteIdentity` value stays current
  with the list — normalized headword keys + kana-folded reading keys —
  and star, highlight matching, and promotion all read it. A store that
  cannot open or load degrades terminally for that instance: every
  mutation fails into one keyed persistent red toast, reads answer empty
  stubs, and the window shows a degraded card (a relaunch builds a
  fresh store; deleting `favorites.sqlite` starts over).
- **Matching (render path):** a rendered segment matches when its surface
  equals a stored headword (NFKC-folded); or, for a non-bound lemma, when
  the lemma equals a stored headword, is an all-kana form whose kana fold
  equals a stored reading (もらって → もらう), or unwraps from a
  potential/passive shape to one (勝て → 勝てる → 勝つ, spelling or
  reading); or when an all-kana surface kana-folds onto a stored reading —
  starring 見る lights up 見た / 見ます / 見ている, starring 有難う lights
  up ありがとう; a kanji surface is never a reading match. The lemma arms
  skip bound tokens (`isBound`) — they lemmatize away from what is on
  screen, so starring ない must not light ねえ / なきゃ / なし; a bound
  token still matches on its exact surface. The hot path probes the
  identity's in-memory sets (`FavoriteIdentity.keys` / `.readings`) per
  rendered segment and never touches SQLite; `FavoritesStore.revision` is
  the observation transcript rows read to repaint. Favorites render in
  `Theme.favoriteAccent` in the transcript, the live strip, and the HUD —
  wherever `RubyTextView` renders per-segment units: the dictionary path
  in every annotation mode (Favorite segments staying their own units even
  where nothing else is annotated) and Romaji/Furigana on the legacy path;
  None on the legacy path renders one plain uncolored surface.
- **Favorites mode (reference window):** the starred words live in the
  reference window's Favorites mode (see Dictionary search above) — one
  460×775.6 two-mode window, so Favorites and dictionary search share one
  footprint, one debounce, and one close-time reset. An explainer card, a
  debounced search against the SQLite list (LIKE with escaped wildcards
  across headword / reading / romaji), and Favorite rows
  (copy → star → chevron) that expand into the shared Entry view via live
  `JMDictLookup` queries (`FavoritesLookupState` — row-keyed phases behind
  generation tokens: headword here, entry id in search; deliberately never
  the app-wide popover/card pipeline). Opened by the floating star over
  the transcript (top-trailing,
  sharing the toast stack's column beside the book opener); search,
  expansion set, and the pending removal question reset when the window
  closes.
- **Favorite-first lookup:** `FavoritesPromotion` reorders an
  already-resolved Lookup once so a starred Entry written or read as the
  looked-up word leads the Display's pager, every `also:` Hit's
  pager, and each expanded search row's pager — a fallback pill labels
  itself with its lead Entry, so the promotion is what makes an eligible
  pill readable and starred, and `selectAlsoPill` re-promotes the content
  it rebuilds. A starred sibling spelling — matched through another
  writing — stays where the engine ranked it. Bare-miss pins stay that way
  with no Display (a Split hit must never present itself
  as the tapped word), though each Related set is promoted the
  same way, so a buried eligible Favorite leads its pill before any
  re-select. The dictionary engine itself never learns Favorites exist.

### Model choice (`Model/`)
- `ASRModelChoice` — `.lite` / `.full`, each carrying its metadata (GGUF
  name, HF repo + pinned revision, pinned SHA-256, size, tradeoff copy):
  Lite = `sensevoice-small-q8_0.gguf` (~250 MB, default), Full =
  `funasr-nano-2512-q8_0.gguf` (~1.2 GB). Selection persists to
  UserDefaults key `"asr.model"`; both GGUFs live side-by-side in the
  shared models directory, and the choice's repo id doubles as the session
  file's `model` metadata.
- Resolution per choice: `Bundle.main` →
  `~/Library/Application Support/Mimidasu/models/` → dev checkout
  (DEBUG builds only) — every candidate, bundled included, must pass
  SHA-256 verification. `ModelVerifier` checks the pinned SHA-256 behind a
  two-tier positive-verdict cache keyed (path, size, mtime) — an in-process
  hot set plus a persisted `verification-cache.json`, so switching never
  re-hashes the other model; `ModelDownloader` handles resume / cancel /
  verify-and-replace, verifying at the temp location so a bad download
  never reaches the model path.
- A model must be downloaded **and verified** before selection. Selection
  is refused while `.starting` / `.running` / `.paused` (Settings disables
  the rows); there is no queued mid-session switch. Completing a Settings
  download auto-selects (engines are built per session; the path-keyed
  warm-up re-arms on the new model so the next start loads it hot). No
  resolvable model → the labeled mock transcriber.

### Onboarding
- First launch with no verified model swaps the main shell for
  `OnboardingView` (compact window footprint, restored on completion): a
  permission/privacy explainer (system-audio TCC, local processing) and a
  SPEECH MODEL card with one row per choice — pick + download with
  progress / retry / cancel; completion auto-advances into the main UI.
  The model can be swapped later in Settings.

### AppModel + SessionController (`State/`, `Session/`)
- `AppModel` (@MainActor `@Observable`): session phase (including
  `.paused` and `.sourceLost`), transcript entries, translation status
  (forwarded from the live-session coordinator), archive state (`archive` /
  `archiveRead`, `recordingSessionID`, `archiveWriteFailed`, `openArchive`,
  `archiveViewingLanguage`, `archiveTranslationJob`), HUD pin, toast/notice
  stacks, audio level + latency, ASR model state, lookup state (popover +
  pinned card), the Favorites store (star outcomes + the segment matcher),
  session clock / loss / pause anchors, and the two translation
  coordinators — `translationSession` / `retranslate` — plus the shared
  `AppleTierAvailability` module. The coordinators own provider attach /
  fallback latch / lane machinery and the **three**
  `TranslationSession.Configuration`s (the live session's plus the
  re-translate lane's dedicated Apple (NMT) / Apple Intelligence pair), exposed
  through computed façade pass-throughs. Split into extensions
  (`AppModelArchive` / `ArchiveTranslation` / `ArchiveWriteBack` /
  `CaptureWarnings` / `Dictionary` / `Export` / `Favorites` / `Lookup` /
  `ModelSelection` / `Overlay` / `Pause` / `Retranslate` / `SessionControl`
  / `Termination` / `Translation`) — `SessionControl` owns the start
  surface (guards, failure freeze, the phase-race guard where a `stop`
  during `begin` tears down whatever `begin` brought up, and the guard
  that drops a start failure landing after a raced teardown so it can't
  resurrect `.failed`); `Pause` owns pause-span accounting and the
  resume/rebuild path; `Termination` latches `isTerminating` so a second
  quit-time shutdown notification can't run a concurrent teardown.
  Injectable test seams: a scripted `SessionController` (engine / capture
  / warm-up / watchdog-grace factories), a stubbed model resolver, the
  terminate-notification center, the HTTP translation transport, the
  Apple Intelligence probe, the translation/adapter settings, the archive
  store/read model, the Favorites store, and the dictionary engines.
- `SessionController`: engine creation via `ASREngineFactory` + background
  warm-up (path-keyed; a model switch re-arms it), capture wiring, the
  sentence buffer, the 60 ms poll / 200 ms tick timers, ASR event →
  sentence handling, mid-session capture restart (no model reload), and
  pause/resume. `pause()` freezes only capture: the in-flight utterance is
  flushed through the engine exactly once, the sentence buffer closes, and
  live surfaces clear, while timers and translation keep running;
  `resume()` restarts the IOProc, re-arms a fresh watchdog grace, and
  resets the presence latch. Pause/resume/restart/stop are serialized on a
  main-actor transition tail; `stop` latches `stopRequested` synchronously
  and `hasStopped` makes teardown one-shot.
- Teardown order: capture stop → watchdog disarm → `SessionEngineChannel`
  finish (consuming any airborne pause flush) off-main with drained events
  replayed → timers → buffer flush → bounded translation drain. The 60 ms
  poll tick also publishes latency (pushed − processed samples) and drains
  chunk RMS into the audio meter plus a one-shot audio-detected flag
  through `Mutex`-guarded handoffs. A one-shot silence watchdog surfaces a
  no-audio warning when a fresh capture stays below the silence floor (8 s
  grace, armed at the `.running` flip so the TCC prompt doesn't mis-warn,
  disarmed by pause/stop and re-armed by resume/restart); the first
  audible signal retires it. Capture lost flips the phase to
  `.sourceLost`, latches the loss anchor, and posts the Restart capture
  card; while
  paused the error is deferred to the resume path, where a failed rebuild
  enters `.sourceLost`. Restart rebuilds only the capture — engine, timers,
  buffer, session clock, and the fallback latch all survive.

### Session archive (`Archive/`)
- **Store:** `ArchiveStore` is a synchronous façade over `ArchiveDatabase`
  (called on the main actor; SQLite at
  `Application Support/Mimidasu/archives.sqlite`; container-relative in the
  sandboxed Release build). One schema creates `sessions` (status,
  timestamps, active `duration_ms`, `paused_ms`, target/model/chunk
  metadata, `saved`, `name`), `sentences` (`(session_id, idx)` PK, spans,
  lang, transcript), `translations` (`(session_id, idx, lang)` PK, text,
  nullable `engine`), and `session_languages` membership, all with cascading
  deletes. The schema is idempotent DDL with no version/migration mechanism.
- **Lifecycle:** the first finalized sentence creates a `recording` row;
  every later sentence is appended and every landed translation is
  upserted through the write-back seam (`AppModel.writeBackTranslation`).
  Stop finalizes the row as an unsaved Recent with pause-excluded duration;
  empty sessions create no row. A launch sweep flips abandoned `recording`
  rows to `interrupted` (dating the end from the last sentence when no
  finalized duration exists). The 10-session Recent cap evicts oldest-first
  and exempts Saved and recording rows; Saved sessions have no cap.
- **Read model:** `ArchiveReadModel` (@MainActor `@Observable`) owns the
  cached summary list, typed availability (`available` / `openFailed` /
  `readFailed`), and a revision bumped once per landed mutation. The
  archive window reads only cached rows; a full reload replaces the list,
  row mutations refresh one row, and failed writes change neither cache nor
  revision. A terminal open failure degrades every operation; per-operation
  read failures keep the prior rows and expose the typed state.
- **Bulk re-translation:** `ArchiveTranslationJob` is a main-actor state
  machine with a synchronous one-run-at-a-time claim, scopes `missing` /
  `all` / `failedOnly`, injected provider resolver and landing closures,
  and one provider call per sentence. It resolves the provider from the lane
  (Apple tiers wait for the lane chain / availability hand-over; external
  providers use stored keys and the disclosure sheet fires first), stamps
  every landed row's `engine`, and writes back through the same seam as
  live and per-row translation. Progress/summary is an `.info` toast card
  with Cancel / Retry failed; a failed write counts as a failed sentence.
- **Window and pane:** a fixed 640×720 `Window("Session archive")` scene
  splits rows into RECENT and SAVED, newest first. Each row carries a date
  rail, a large title (the user's name, the quoted first sentence, or
  "Untitled session"), an excerpt under a renamed title, time/duration/sentence meta,
  language chips with completeness meters, interrupted badges,
  save/rename/delete actions, and a bulk-job progress bar; the window shows a
  live-session hint above the list. Opening an Archived session is gated while
  any Session is live. An Archived session fills the main pane with a banner
  (date/tier kicker, large title with rename, duration/sentence/character
  stats, and a toolbar for the viewed-language switch, the Translate provider
  picker, and the save bookmark) and archived SessionEntries that still
  support lookup, copy, export, and per-SessionEntry re-translation. Opening
  an Archived session cancels the bulk job, resets the viewing language and
  dictionary/HUD anchors, and bumps the re-translate epoch; closing clears
  the pane without restoring it.
- **Interactions:** an open Archived session blocks starting a new Session
  until it is closed (the UI offers to close it); pause updates the live
  row's `paused_ms` but never finalizes; stop from paused closes the pause
  span first. Export uses the normal exporter, with JSON metadata from the
  Archived session and the Session name as the filename stem.

### UI (`UI/`, SwiftUI `@MainActor`)
- **Main window:** fixed 282 pt sidebar — brand header (耳 mark, Mimidasu,
  "Japanese → \<target\>" subtitle, session archive button), session
  capsule with pause/resume and close-archive companions, ANNOTATION +
  CURSOR MODE pickers, card stack, toolbar — beside a virtualized
  transcript (gutter timestamps, `RubyTextView` JP, teal target-language
  translation, circular jump buttons) with the live partial strip pinned
  under it. In archive mode an `ArchiveBannerView` sits above the
  transcript, the live strip and SESSION card hide, the floating overlays
  are forced off and untogglable, and the capsule's close-archive button
  returns to the live pane. The card stack is cursor-mode-driven: ENGINES +
  AUDIO show together in None/Copy modes and are swapped for the DICTIONARY
  card in Dictionary mode; SESSION shows in live modes (Sentences /
  Duration / Characters / Lag). The toolbar holds the export menu (copy +
  TXT/SRT/VTT/JSON), the overlay master toggle, a UI-scale stepper, and the
  settings gear (a 500 ms debounce guards the gear's close-and-toggle).
- **Top-trailing column:** the toast stack shares one column with two
  floating openers — book (reference window, Dictionary mode) and star
  (Favorites mode) — laid out below the toasts.
- **SessionEntries:** hover reveals a circular re-translate button beside
  the translation (the SessionEntry dims while it runs; a landed lane
  result shows a "· via \<provider\>" provenance suffix when the marker
  toggle is on); the list uses a manual bottom-pin scroll model so
  follow-mode survives virtualization.
- **State split:** high-frequency partials (`LivePartialState`), the audio
  level ring (`AudioLevelState`), and latency (`LatencyState`) are small
  standalone observables, so partial-rate updates never re-render the
  transcript.
- **Floating HUD:** always-on-top, semi-transparent; padlock-locked it is
  click-through except its button cluster, unlocked it drags/resizes and
  its height auto-fits content (offscreen measurement host, top edge
  anchored). Header cluster: padlock, close, and the translation-overlay
  toggle. Single chevrons step its pin through translated entries
  (stepping to the newest clears the pin and re-follows), double chevrons
  jump to the ends — oldest pins the first entry, newest re-follows
  (`HUDHistory` holds the pure semantics).
- **Translation-only overlay:** an independently shown/hidden sibling of
  the HUD (`TranslationOverlayWindow`) — an always-on-top panel listing
  every finalized translation in a bottom-pinned scroll view with its own
  jump buttons and a translation-overlay toggle; padlock-locked it is click-through
  except for its button cluster, unlocked it drags/resizes. The sidebar's
  overlay master switch closes both overlays when any is open and reopens
  the HUD when none are (`toggleOverlays`).
- **Reference window:** the two-mode Dictionary/Favorites surface described
  under Dictionary search and Favorites.
- **Settings:** its own window that auto-closes on resign-key (click
  outside) and hides its title chrome; card stack: privacy/external-
  processing notice, provider card (probe-then-select key verification),
  conditional key card, a "Currently using" row naming the attached
  provider, RE-TRANSLATE card (provider picker in a custom popover listing
  only non-duplicate, available options — `.session` always, Apple (NMT)
  unless provably already live, Apple Intelligence only when offered — plus
  the provenance-marker toggle), TARGET LANGUAGE card (runtime-discovered
  catalog, disabled while a session is live or paused), appearance card,
  SPEECH MODEL card with a Re-check action, SESSION diagnostics (Entries /
  Engine / Translation), and an App Store write-review link in the footer.
- **Onboarding:** the main shell's pre-model state (see Onboarding above).
- **Toasts & notices:** `ToastCenter` — deduped, capped (3 visible) stack
  in four styles: auto-dismissing yellow, persistent yellow, persistent
  red, and a neutral `.info` card (bulk-job progress/summary, with a
  progress payload and conditional closability). Persistent red cards carry
  a fix action (Restart capture, Reconnect, or Open System Settings for the
  no-audio case); cleared on session teardown. `NoticeCenter` — a single
  transient pill (teal confirmations like "Text copied", amber No hit
  notice), 2 s auto-dismiss, rendered only while its window is key (mounted
  in the main and reference windows).
- **Theming & scale:** `Theme.swift` centralizes tokens (`SharedTokens`
  primitives shared with Settings; light warm-paper and dark sakura values
  resolved per appearance); `AppearanceSetting` (system/light/dark,
  a `DynamicProperty` wrapper with a system-scheme observer) applies via
  `.preferredColorScheme`; reading-annotation and cursor modes are plain
  `@AppStorage` enums read per-view. `UIScale` (75–200 %) scales the
  transcript pane (its rows and the archive banner above them), the live
  strip, the HUD and the translation overlay together from one persisted
  value; the sidebar column, the archive list window, the archive banner's
  popovers and rename alert, and the settings/reference windows keep fixed
  metrics at every scale.
  `RubyTextView` renders inline romaji or furigana; in dictionary mode
  with a host lookup handler it renders one tappable unit per segment.

### SessionExporter (`Export/`)
- Plain text (`HH:MM:SS  text`, `MM:SS` under 1 h), SRT/VTT subtitles
  (comma vs dot ms delimiter; cues carry translations only — the JP
  transcript never appears in a cue), and the JSON session file (below).
  Languages are read from fields, never assumed; session metadata included.
  An opened archive supplies the JSON metadata and the sanitized filename
  stem; every format exports the transcript pane's entries.

## Threading model

| Thread/queue | Work |
|---|---|
| Main actor | UI state (`AppModel`), session mechanics (`SessionController`), the serialized pause/resume/restart/stop transition tail and `SessionEngineChannel`, published transcripts/translations, 60 ms `poll()` loop, translation worker |
| Capture (tap IO queue, separate listener queue) | IO-block callback: extract PCM, downmix, track sample clock, slice 160 ms chunks; `SessionController` pushes to the engine and stages RMS/presence |
| ASR decode queue (serial, dedicated) | Window partials + endpoint redecodes; jobs snapshot the session handle under the engine's `Mutex` |
| VAD queue (serial, dedicated) | FireRedVAD passes; speech/silence verdicts feed endpointing |
| Channel tasks (detached) | `flushUtterance` / `finish` pause and teardown drains, replaying events on the main actor |
| Translation | Provider translate calls (suspend without blocking the main actor) |

Rules: the ASR session is single-threaded (one recognizer per session);
decode and VAD jobs coordinate through the engine's `Mutex`, serial queues,
`prepareMutex`, and the finish semaphore, and the C library serializes its
own VAD work. Cross-thread handoff uses value types at the Swift boundaries;
opaque C handles stay inside the engine and HAL ownership types.

## Data flow (sentence lifecycle)

1. SystemAudioCapture slices the tap PCM stream into a 160 ms f32 chunk
   and emits it; `SessionController` forwards it to `ASREngine.push` and
   stages RMS/presence on the capture thread.
2. Polling yields partials (HUD draft; transcript untouched) or finals.
3. Finals append to `SentenceBuffer` with sample-accurate offsets.
4. A tier-1/2/3 boundary closes the Sentence → immutable `Sentence`
   published (JP SessionEntry), enqueued for translation, and persisted
   (the first Sentence creates the archive's `recording` row).
5. `TranslationQueue` resolves → translation published (translated
   SessionEntry), appended to the in-memory session, and upserted into the
   archive.
6. On Pause: the IOProc stops, the in-flight utterance flushes through the
   engine channel as a final, timers and translation keep running, and the
   pause span is excluded from duration. Resume restarts the IOProc.
7. On Stop: capture stops, engine finish/drain, translation queue drains
   (bounded), and the archive row is finalized as a Recent; the session
   becomes exportable.

## JSON session file (authoritative interchange format)

```jsonc
{
  "schema_version": 1,
  "session": {
    "started_at": "2026-08-27T14:32:05+09:00",
    "source_lang": "ja",           // fixed ja today (nullable in the schema
                                   // for a future ASR auto-detect)
    "target_lang": "en",           // the session's selected target (BCP-47;
                                   // English is the default)
    "model": "sensevoice-small-GGUF",   // the active choice's modelID
                                        // ("funasr-nano-GGUF" for full;
                                        // "mock" for the mock transcriber)
    "chunk_ms": 160
  },
  "sentences": [
    {
      "index": 0,
      "start_s": 12.48,
      "end_s": 15.04,
      "lang": "ja",                // per-sentence
      "transcript": "今日はいい天気ですね。",
      "translations": [
        { "lang": "en", "text": "Nice weather today, isn't it?" }
        // a manual re-translate replaces the entry in place (one per
        // language), stamped with its lane provider:
        // { "lang": "en", "text": "…", "engine": "deepl" }
      ]
    }
  ]
}
```

Invariants: consumers read languages from fields (never assume); a
SessionEntry carries at most one Translation per language — a re-translate replaces
its language's entry in place, it never appends; `schema_version` governs
evolution; sentence `index` is stable and keys JP↔translation alignment.

A translation entry may carry an optional `engine` field — the provider
that produced it through the re-translate lane or an archive bulk run
(`appleFast` / `appleHighFidelity` / `google` / `deepl` / `openrouter`;
only Apple Intelligence is gated to macOS 26.4+ — the Apple (NMT) lane
exists on every supported OS, and is a genuine alternate while an external
provider is live). Live queue results never carry the field (absent = the
Session engine), so old documents and fresh live-captions-only sessions are
byte-identical; archive runs stamp every result, including an archive
`.session` re-translate that maps to Apple (NMT). The field is additive
under schema v1. Whether re-translated SessionEntries also show the
provider inline in the UI is a Settings toggle
(`translation.retranslateMarker`, default on).

## App bundle layout

```
Mimidasu.app/
  Contents/
    MacOS/Mimidasu                      # Swift binary
    Frameworks/
      crispasr/                         # libcrispasr.dylib + ggml companions
                                        # + firered-vad.gguf, @loader_path rpath
      libdictionary.dylib               # dictionary tokenizer (C FFI)
    Resources/
      system.dic.zst                    # IPADIC tokenizer model (~8 MB),
                                        # decompressed once on first launch
      jmdict-<tag>.<rev>.sqlite.zst     # JMDict + JMnedict lookup DB,
                                        # versioned by pin tag + build revision
      (Assets.car, PrivacyInfo.xcprivacy, README.txt,
       THIRD_PARTY_NOTICES.txt, LICENSE.txt)
      # MAS adds LICENSE-MAS.txt + embedded.provisionprofile
```

Distribution: `scripts/package.sh` builds the release DMG (ULMO-compressed;
dictionary data bundled, ASR model downloaded on first launch) signed so
system-audio recording grants persist; `scripts/notarize.sh` re-packages
with a Developer ID identity and notarizes. `scripts/package_mas.sh`
builds the sandboxed Mac App Store pkg. Shared staging
(`scripts/lib/staging.sh`) hard-fails when the ASR runtime, dictionary
dylib, or bundled dictionary data is missing.

## Dependencies

| Component | License | Notes |
|---|---|---|
| CrispASR runtime (+ ggml) | MIT | Embedded dylib set; dlopen'd, Metal backend |
| FireRedVAD (GGUF) | Apache-2.0 | Bundled beside the dylibs, endpointing |
| SenseVoice-Small GGUF (Q8_0) — Lite | Apache-2.0 | First-launch download, SHA-256 pinned, default choice |
| FunASR-Nano GGUF (Q8_0) — Full | Apache-2.0 | First-launch download, SHA-256 pinned (HF LFS oid), opt-in choice |
| Dictionary tokenizer (vendored vibrato runtime) | Apache-2.0 OR MIT | Embedded as `libdictionary.dylib`; crate tracked under `ffi/vibrato-ffi/` |
| IPADIC v2.7.0 dictionary model | Custom permissive (NAIST et al.) | Bundled as `system.dic.zst`; decompressed on first launch |
| JMdict (EDRDG, via JMDict_Extended) | CC BY-SA 4.0 (data); MIT (compile) | Pinned lookup DB; full terms in THIRD_PARTY_NOTICES |
| JMnedict (EDRDG, via jmdict-simplified) | CC BY-SA 4.0 | Pinned names asset, ingested into the same DB |
| Apple Translation framework | Platform | macOS 15+, on-device; Apple Intelligence strategy on 26.4+ |
| Core Audio process tap | Platform | macOS 15+; requires system-audio recording permission |

Compatibility: Apple Silicon, macOS 15.5+.

## Latency budget (expected)

| Stage | Cost |
|---|---|
| ASR chunk (algorithmic) | 160 ms fixed |
| Partial decode | step-spaced (1 s) window decodes; fast on the non-AR backends (Lite's SenseVoice: hundreds of ms; Full's FunASR ~4–5× slower but still real-time) |
| Sentence close + translation | ~2–4 s after sentence end |
| **End-to-end vs. live** | **multi-second** (dominated by decode latency + sentence completion) |
