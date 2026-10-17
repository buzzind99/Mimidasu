# Architecture

**Mimidasu** — a real-time Japanese livestream transcriber/translator for
macOS (Apple Silicon, 15.5+). Captures system audio via a Core Audio process
tap, streams it through a selectable ASR GGUF — **Lite** (SenseVoice-Small,
default) or **Full** (FunASR-Nano) — via the CrispASR runtime with
FireRedVAD endpointing, and translates finalized sentences to a selectable
target language (English by default) with Apple's on-device Translation
framework — or Apple Intelligence's high-fidelity strategy where installed —
or an optional cloud provider (Google Translate, DeepL, OpenRouter) behind
the same engine seam. Ruby
annotations (romaji/furigana) and tap-to-lookup dictionary entries come
from a bundled IPADIC tokenizer plus a pinned JMDict/JMnedict SQLite DB,
which also powers a full-dictionary search (Japanese / romaji / English
gloss) in a two-mode reference window. Starred words persist to a
searchable favorites list and render highlighted wherever Japanese text is
shown.

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
  scope, match-tier, JLPT, POS, and name-type filters.
- **FavoritesStore / FavoritesDatabase / FavoriteIdentity /
  FavoritesPromotion** — starred words: SQLite persistence, one identity
  value behind star/highlight/promotion, transcript highlight matching,
  favorite-first lookup ranking.
- **RetranslateCoordinator + the re-translate lane** — manual per-row
  re-translate of a finalized sentence through a user-selected engine
  (dedicated Apple sessions, serialized lane, provenance stamps).
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
- Permission: system-audio recording (TCC, separate from Microphone). The
  prompt fires on the aggregate's first IO; a refusal surfaces a pointer to
  System Settings.
- Failure: device death / tap removal listeners emit `.captureLost`
  (Restart toast); unreadable formats emit `.formatUnavailable`; output
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
- **FireRedVAD** runs every 500 ms on its own queue and is the
  authoritative speech signal: it gates partial decodes, and 1.0 s of
  analyzed audio past the last VAD speech span end finalizes the utterance
  (the VAD's own internal span-closing silence is 800 ms; speechless
  buffers are discarded without decoding). A cheap per-chunk RMS check is
  only a backstop (and covers degraded mode when the VAD model is
  unavailable).
- 1 s-step window decodes post `.partial` (HUD draft); the endpoint
  redecodes the buffered utterance PCM and posts one clean `.final`.
- Lifecycle: symbol binding happens once at engine init (`CrispASRLibrary`);
  `prepare` reuses a warm open session and skips the GGUF reload →
  `openStream` → `push` per chunk → `poll` from a 60 ms timer → `finish`
  (drain + final flush; the session **stays warm**). `close()` runs only
  when the factory retires the engine (model swap or quit). Decodes run on
  a dedicated serial queue so `poll` never blocks behind a multi-second
  decode; teardown is strictly ordered (capture stop → finish/drain →
  close).
- `ASREngine` protocol + factory: CrispASR when the runtime and model
  resolve, otherwise the labeled mock transcriber (finals only, RMS-gated,
  randomized speech cadence). The factory holds a path-keyed warm-engine
  cache, a `retired` latch, and a runtime-poison latch for a leaked
  `close()`; a quit-time shutdown frees the VAD cache.

### SentenceBuffer (`Session/`)
- Streaming ja ASR routinely drops punctuation, so boundaries are 3-tier:
  1. Terminal punctuation (`。！？` plus ASCII `!`/`?`) closes immediately.
  2. No new finals for ~1 s finalizes the buffer.
  3. 42-char cap, split at the first clause boundary found at/after 18
     chars, scanning the fixed priority `けど` / `から` / `ので` / `って` /
     `、` / `,`.
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
  accepts any engine; `Translation/Providers/` holds the cloud adapters.
- **Coordination:** `TranslationSessionCoordinator` owns the live
  attach/retry/fallback/probe/provider machinery and
  `RetranslateCoordinator` owns the lane; `AppModel` keeps phase, entries,
  and toasts and forwards through façade extensions over
  `TranslationSessionPort` (`phase` · `toasts` · `applyTranslation`).
- **Engines:** Apple on-device (`AppleSessionEngine` fed by SwiftUI's
  `.translationTask`, hosted in a process-lifetime 1×1 panel
  (`TranslationSessionPanelController`) so closing the main window can't
  cancel the task and strand the queue's pending sentences; the default;
  OS prompts a one-time language pack), and Google Translate, DeepL,
  OpenRouter. On macOS 26.4+ the live session config requests the
  high-fidelity (Apple Intelligence) strategy, with silent framework
  fallback to the fast model; a per-activation probe checks whether the
  strategy is actually installed for ja→target — only an installed pair
  counts — and the ENGINES card labels it "Apple Intelligence". The same
  panel hosts two more lazily-armed `.translationTask` hosts dedicated to
  the re-translate lane (fast + high-fidelity), stacked in one view tree
  because multiple modifiers on one view are unreliable.
- **Cloud adapters:** Google Translate (batch REST), DeepL (batch REST,
  `:fx` free-tier host), OpenRouter (chat completions, **one sentence per
  request** with a plain-text prompt parsed leniently — no JSON contract —
  and a default model when Settings leaves the field empty). Source is
  fixed `ja`; the target follows the selection. Provider switching is
  live: a verified selection re-attaches the engine mid-session (pending
  sentences replay via the queue's generation token; the Apple-fallback
  latch resets — an explicit change is user intent to re-engage), and a
  key save's connection test re-attaches an already-selected provider once
  it verifies (a fresh switch still completes through the disclosure
  sheet).
- **Target language:** `TargetLanguage` carries a BCP-47 entry code plus
  per-engine mappings (Google/DeepL API codes; OpenRouter prompts name the
  language); the selection persists as `translation.targetLanguage` and is
  restart-only — the picker disables while a session is live. The picker's
  catalog is `LanguageAvailability.supportedLanguages` intersected with a
  static metadata table (per-engine codes + display names); Apple-
  discovered codes missing from the table don't ship in the picker, and a
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
  malformed output fail fast — except chat-completions engines, which
  retry malformed output (nondeterministic LLM replies) while fixed-
  contract Google/DeepL never do. Settings' Test probes run zero-retry
  (Google/DeepL translate a probe sentence; OpenRouter validates the key
  via a key endpoint so no tokens are spent), and the outcome persists per
  provider.
- **Failure ladder:** exhausted external errors latch Apple on-device for
  the rest of the session (one-way per session; `.degraded` published; the
  footer's manual Reconnect re-attempts the external engine and resets the
  latch). Apple itself failing publishes `.unavailable` with **no** engine
  swap — Reconnect is the only way back. A selected-but-unconfigured
  provider (key deleted) degrades to Apple at activation — no toast; the
  footer and ENGINES card surface the state.
- **Keys:** `KeychainStore` (`Security/`, device-only accessibility);
  key material never reaches UserDefaults, logs, error strings, or export
  files — the settings store persists non-secrets only (provider
  selection, key-presence flags + hints, test outcomes, the OpenRouter
  model, DeepL free-tier). Dev builds pin the key store to a no-op, so
  development always runs Apple on-device.
- **Disclosure:** activating any cloud provider — for the live session or
  the re-translate lane — requires confirming `CloudDisclosureSheet` with
  intent-aware copy ("sentences transcribed from your Mac's audio will be
  sent to \<provider\>" for a switch; only explicitly retried lines for the
  lane), raised on every switch to an external engine; audio itself never
  leaves the machine.
- **Re-translate lane:** a finalized row can be re-translated through a
  user-selected engine (`session` / `appleFast` / `appleHighFidelity` /
  `google` / `deepl` / `openrouter`, persisted as
  `translation.retranslateEngine`). Selections naming the live session
  engine route through the queue unstamped; anything else runs through a
  serialized lane of chained tasks with dedicated, lazily-armed Apple
  sessions (explicit `preferredStrategy`, so a lane can't silently
  duplicate the live model), Apple lanes deferring behind the
  availability probe's landing. Dispatching drops any queued copy;
  landings stamp the row's `engine` provenance and seed the repeat cache
  (unstamped).
  High-fidelity picks degrade to fast where the strategy is known
  unavailable; delivery is session-epoch-guarded so a stale lane can't
  write into a new session; failures post yellow toasts.
- **Status surface:** `TranslationPill.map(status:activeEngine:fallbackActive:)`
  derives the pill/card dot tone (a latched `.ready` reads yellow; every
  label is "On-device" or "External"); the sidebar titles the attached
  engine (`SidebarStatus.translationEngineName` — "Apple Intelligence"
  when the high-fidelity pair is installed, else "Apple", or the provider)
  over a detail line mirroring state ("On-device (fallback)",
  "Unavailable", "External"); retry/fallback/unavailable states surface
  as toasts.

### Reading annotation & dictionary lookup (`Text/`, `Dictionary/`)
- **Annotator:** `ReadingAnnotator` tokenizes via `DictionaryEngine`
  (dlopen'd `libdictionary.dylib`, bundled IPADIC) and emits segments
  `{surface, romaji, furigana, lemma, pos, isBound}` — one segmentation
  feeds both annotation modes and the favorite matcher. The tokenizer
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
- **Fail-soft:** a missing dylib or model means plain runs that still
  concatenate back to the original; preparation retries next launch.
- **Lookup data:** pinned JMDict_Extended (`1.4.1-auto-release-2026-09-01`)
  + JMnedict (`3.6.2+20260914172325`), build revision 7. The pins live in
  `Dictionary/JMDictPin.swift` and are asserted by
  `scripts/build_dictionary.sh`, whose format probe hard-fails on upstream
  drift. Both sources build into one `jmdict-<tag>.<rev>.sqlite`
  (entries/senses/headwords/meta); JMnedict names ride `ent_seq + 10M` in
  the same tables. Sense glosses are stored joined with `U+001F` so
  display-side splitting can't shred glosses containing `"; "`, and the
  artifact bundles a partial case-headword index (`headwords` rows whose
  text isn't all-lowercase — the case-spelling rescue for search). The DB
  bundles as `jmdict-<tag>.<rev>.sqlite.zst` — the tag + build revision is
  the staleness key, stale prepared artifacts are swept. Both DBs
  decompress once to Application Support on first launch (offline,
  smoke-checked), where preparation additionally derives a contentless
  **FTS5 trigram index over glosses** (rowid-packed by entry, promoted
  only after a smoke probe) — derived, never bundled; a debug-only
  `jmdict-<tag>.<rev>.dev.sqlite` (the build script's index-carrying
  intermediate in `build/`, which debug checkouts and the live tests
  resolve) sits outside the prepared directory and so is never swept.
- **Tap-lookup engine:** `JMDictLookup` — typed errors (no-hit ≠
  infrastructure failure; a headword row whose entry is missing reports
  `databaseCorrupt`), homograph entries ranked by four keys (tapped
  writing match, segment-reading match, common, `ent_seq`), sense
  restriction filters honored, NFKC folding at every SQL boundary.
  `JMDictExpansion` builds ≤9 ranked candidates per tap — the tapped
  surface, its lemma, a potential/passive unwrap (`作れる`/`作られる` → 作る,
  `される` → する), forward joins of up to 6 segments, then ≤3-char
  kanji-run splits run twice (over the tapped surface and over the joined
  expansion text, so boundary-crossing words like 風呂+敷 → 呂敷 resolve) —
  resolved in that order, validated against the sentence's render text
  (drift fails closed; the tapped segment still queries). A join hit may
  lead the card (JOINED MATCH badge); a split-only tap resolves not-found
  with the split hits demoted to related pills — a split never presents
  itself as the tapped word.
- **Display module:** `LookupDisplay` (resolve → promote → pager math)
  is pure value logic beside `TapLookupRequest` / `TapLookupEffect` /
  `TapLookupFault`; `AppModelLookup` only wires effects to state, toasts,
  and notices. Sense rows render every stored POS tag as its own badge
  (stored order), and the sidebar card stacks a multi-tag sense's tags
  above its gloss.
- **Tap surface:** cursor modes None / Dictionary / Copy. A tap resolves
  through the pipeline and pins the sidebar DICTIONARY card plus a popover
  anchored at the word; homograph entries walk via the `◀ i/N ▶` pager,
  fallback hits surface as capped (9) "also:" pills (a forward-join
  *display* lead wears the JOINED MATCH badge; split-only taps show
  "related:" pills), pills are selectable and re-pin their chosen result
  as the display (origin reset to the tapped surface, favorites promotion
  re-applied), a bare miss posts the amber
  notice pill, and an infrastructure failure posts a toast. Name entries
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
  since pre-join emptiness proves nothing: probe the base form first, then
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
- **Filters:** scope (All / Words / Names), COMMON-only, match tiers
  (exact / prefix / gloss — the last enabled can't be switched off), JLPT
  N1–N5, 11 rule-based POS groups, and 22 name-type badges. JLPT and POS
  are mutually exclusive with name types under All; every effective
  filter press re-runs the search against the debounced query and
  re-pages to page 1 (a no-op press writes nothing and re-runs nothing).
  All filter writes go through the pure `DictionaryFilterTransition` —
  `DictionarySearchState.apply(_:)` is the single funnel, and the
  transition owns the scope carry-over, the All-scope exclusions, the
  match-group floor, and the COMMON-under-Names canonicalization.
- **Reference window:** one fixed 460×775.6 window (`Window("Dictionary")`)
  with two persisted modes — **Dictionary** (default) and **Favorites** —
  flipped by a header button, one shared 150 ms search debounce, focus
  hand-off between the modes' fields, a `displayed / matched(+)` count,
  and close-time state reset for both modes. Opened from the floating
  book opener over the transcript or the sidebar DICTIONARY card's kicker.
  Results render as favorites-shaped cards (match badge first, then
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

### Favorite words (`Favorites/`)
- **Star surface:** the dictionary popover, the sidebar DICTIONARY card,
  the search list, and the Favorites list all mount one
  `DictionaryFavoriteButton` (the pill star is the separate lead probe),
  keyed by the displayed entry's headword (non-empty `keb`, else `reb`) —
  homographs share one star and one list row. Starring twice is
  idempotent; un-starring never happens silently — the press raises
  `FavoriteRemovalConfirmation`, one alert per window: the main window
  owns the question for the popover + sidebar card, the reference window
  owns one for its search and favorites rows, and a `.popover` never
  presents the alert. The not-found state carries no star; an `also:` pill
  stars only through its promoted lead entry (the not-found host passes no
  favorites probe).
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
  stubs, and the window shows an unavailable card (a relaunch builds a
  fresh store; deleting `favorites.sqlite` starts over).
- **Matching (render path):** a rendered segment matches when its surface
  equals a stored headword (NFKC-folded); or, for a non-bound lemma, when
  the lemma equals a stored headword, is an all-kana form whose kana fold
  equals a stored reading (もらって → もらう), or unwraps from a
  potential/passive shape to one (勝て → 勝てる → 勝つ, spelling or
  reading); or when an all-kana surface kana-folds onto a stored reading —
  favoring 見る lights up 見た / 見ます / 見ている, favoring 有難う lights
  up ありがとう; a kanji surface is never a reading match. The lemma arms
  skip bound tokens (`isBound`) — they lemmatize away from what is on
  screen, so favoring ない must not light ねえ / なきゃ / なし; a bound
  token still matches on its exact surface. The hot path probes the
  identity's in-memory sets (`FavoriteIdentity.keys` / `.readings`) per
  rendered segment and never touches SQLite; `FavoritesStore.revision` is
  the observation transcript rows read to repaint. Favorites render in
  `Theme.favoriteAccent` in the transcript, the live strip, and the HUD —
  wherever `RubyTextView` renders per-segment units: the dictionary path
  in every annotation mode (favorite segments staying their own units even
  where nothing else is annotated) and Romaji/Furigana on the legacy path;
  None on the legacy path renders one plain uncolored surface.
- **Favorites mode (reference window):** the starred list lives in the
  reference window's Favorites mode (see Dictionary search above) — one
  460×775.6 two-mode window, so favorites and dictionary search share one
  footprint, one debounce, and one close-time reset. An explainer card, a
  debounced search against the SQLite list (LIKE with escaped wildcards
  across headword / reading / romaji), and dictionary-card rows
  (copy → star → chevron) that expand into the shared entry view via live
  `JMDictLookup` queries (`FavoritesLookupState` — row-keyed phases behind
  generation tokens: headword here, entry id in search; deliberately never
  the app-wide popover/card pipeline). Opened by the floating star over
  the transcript (top-trailing,
  sharing the toast stack's column beside the book opener); search,
  expansion set, and the pending removal question reset when the window
  closes.
- **Favorite-first lookup:** `FavoritesPromotion` reorders an
  already-resolved lookup once so a favorited entry written or read as the
  looked-up word leads the display result's pager, every `also:` hit's
  pager, and each expanded search row's pager — a fallback pill labels
  itself with its lead entry, so the promotion is what makes an eligible
  pill readable and starred, and `selectAlsoPill` re-promotes the content
  it rebuilds. A starred sibling spelling — matched through another
  writing — stays where the engine ranked it. Not-found pins stay
  not-found with no display result (a split hit must never present itself
  as the tapped word), though each related suggestion is promoted the
  same way, so a buried eligible favorite leads its pill before any
  re-select. The dictionary engine itself never learns favorites exist.

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
- A model must be downloaded **and verified** before selection; a
  mid-session switch applies at next session start; completing a Settings
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
  `.sourceLost`), transcript entries, translation status (forwarded from
  the live-session coordinator), HUD pin, toast/notice stacks, audio level
  + latency, ASR model state, lookup state (popover + pinned card), the
  favorites store (star outcomes + the segment matcher), session
  clock/loss anchors, and the two translation coordinators —
  `translationSession` / `retranslate` — which own the engine attach /
  fallback latch / probe machinery and the **three**
  `TranslationSession.Configuration`s (the live session's plus the
  re-translate lane's dedicated fast / high-fidelity pair), exposed
  through computed façade pass-throughs. Split into extensions
  (`AppModelTranslation` / `CaptureWarnings` / `Dictionary` / `Export` /
  `Favorites` / `Lookup` / `ModelSelection` / `Overlay` / `Retranslate` /
  `SessionControl` / `Termination`) — `SessionControl` owns the start
  surface (guards, failure freeze, the phase-race guard where a `stop`
  during `begin` tears down whatever `begin` brought up, and the guard
  that drops a start failure landing after a raced teardown so it can't
  resurrect `.failed`), and `Termination` latches `isTerminating` so a
  second quit-time shutdown notification can't run a concurrent teardown.
  Injectable test seams: a scripted `SessionController` (engine / capture
  / warm-up / watchdog-grace factories), a stubbed model resolver, the
  terminate-notification center, the HTTP translation transport, the
  high-fidelity probe, the translation/adapter settings, the favorites
  store, and the dictionary engines.
- `SessionController`: engine creation via `ASREngineFactory` + background
  warm-up (path-keyed; a model switch re-arms it), capture wiring, the
  sentence buffer, the 60 ms poll / 200 ms tick timers, ASR event →
  sentence handling, mid-session capture restart (no model reload), and
  strictly ordered teardown (capture stop → watchdog disarm → engine
  finish/drain off-main with drained events replayed → timers → buffer
  flush → bounded translation drain). The 60 ms poll tick also publishes
  latency (pushed − processed samples) and drains chunk RMS into the
  audio meter plus a one-shot audio-detected flag through `Mutex`-guarded
  handoffs. A one-shot silence watchdog surfaces a no-audio warning when
  a fresh capture stays below the silence floor (8 s grace, armed at the
  `.running` flip so the TCC prompt doesn't mis-warn); the first audible
  signal retires it. Capture death flips the phase to `.sourceLost`,
  latches the loss anchor, and posts the Restart card; the restart
  rebuilds only the capture — engine, timers, buffer, session clock, and
  the fallback latch all survive.

### UI (`UI/`, SwiftUI `@MainActor`)
- **Main window:** fixed 282 pt sidebar — brand header (耳 mark, Mimidasu,
  "Japanese → \<target\>" subtitle), session capsule, ANNOTATION + CURSOR
  MODE pickers, card stack, toolbar — beside a virtualized transcript
  (gutter timestamps, `RubyTextView` JP, teal target-language translation,
  circular jump buttons) with the live partial strip pinned under it. The
  card stack is cursor-mode-driven: ENGINES + AUDIO show together in
  None/Copy modes and are swapped for the DICTIONARY card in Dictionary
  mode; SESSION shows in every mode (Sentences / Duration / Characters /
  Lag). The toolbar holds the export menu (copy + TXT/SRT/VTT/JSON), the
  overlay master toggle, a UI-scale stepper, and the settings gear (a
  500 ms debounce guards the gear's close-and-toggle).
- **Top-trailing column:** the toast stack shares one column with two
  floating openers — book (reference window, Dictionary mode) and star
  (Favorites mode) — laid out below the toasts.
- **Transcript rows:** hover reveals a circular re-translate button beside
  the translation (row dims while it runs; a landed lane result shows a
  "· via \<engine\>" provenance suffix when the marker toggle is on); the
  list uses a manual bottom-pin scroll model so follow-mode survives
  virtualization.
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
  jump buttons and a subtitle toggle; padlock-locked it is click-through
  except for its button cluster, unlocked it drags/resizes. The sidebar's
  overlay master switch closes both overlays when any is open and reopens
  the HUD when none are (`toggleOverlays`).
- **Reference window:** the two-mode Dictionary/Favorites surface described
  under Dictionary search and Favorite words.
- **Settings:** its own window that auto-closes on resign-key (click
  outside) and hides its title chrome; card stack: privacy/external-
  processing notice, provider card (probe-then-select key verification),
  conditional key card, RE-TRANSLATE card (engine dropdown listing only
  non-duplicate, available options + the provenance-marker toggle), TARGET
  LANGUAGE card (runtime-discovered catalog, disabled while a session is
  live), appearance card, SPEECH MODEL card with a Re-check action, SESSION
  diagnostics (Entries / Engine / Translation), and an App Store
  write-review link in the footer.
- **Onboarding:** the main shell's pre-model state (see Onboarding above).
- **Toasts & notices:** `ToastCenter` — deduped, capped (3 visible) stack
  in three styles: auto-dismissing yellow, persistent yellow, persistent
  red; persistent red cards carry a fix action (Restart, Reconnect, or
  Open System Settings for the no-audio case); cleared on session
  teardown. `NoticeCenter` — a single transient pill (teal confirmations
  like "Text copied", amber dictionary no-hit), 2 s auto-dismiss, rendered
  only while its window is key (mounted in the main and reference
  windows).
- **Theming & scale:** `Theme.swift` centralizes tokens (`SharedTokens`
  primitives shared with Settings; light warm-paper and dark sakura values
  resolved per appearance); `AppearanceSetting` (system/light/dark,
  a `DynamicProperty` wrapper with a system-scheme observer) applies via
  `.preferredColorScheme`; reading-annotation and cursor modes are plain
  `@AppStorage` enums read per-view. `UIScale` (75–200 %) scales
  transcript, live-strip, and HUD text together from one persisted value.
  `RubyTextView` renders inline romaji or furigana; in dictionary mode
  with a host lookup handler it renders one tappable unit per segment.

### SessionExporter (`Export/`)
- Plain text (`HH:MM:SS  text`, `MM:SS` under 1 h), SRT/VTT subtitles
  (comma vs dot ms delimiter; cues carry translations only — the JP
  transcript never appears in a cue), and the JSON session file (below).
  Languages are read from fields, never assumed; session metadata included.

## Threading model

| Thread/queue | Work |
|---|---|
| Main actor | UI state (`AppModel`), session mechanics (`SessionController`), published transcripts/translations, 60 ms `poll()` loop, translation worker |
| Capture (tap IO queue) | IO-block callback: extract PCM, downmix, track sample clock, slice 160 ms chunks → engine `push` |
| ASR decode queue (serial, dedicated) | Window partials + endpoint redecodes; owns the session handle; runs teardown in strict order |
| VAD queue (serial, dedicated) | FireRedVAD passes; speech/silence verdicts feed endpointing |
| Translation | Engine translate calls (suspend without blocking the main actor) |

Rules: the ASR session is single-threaded (one recognizer per session);
the engine's decode and VAD jobs interlock only through the engine's state
lock; cross-thread handoff uses value types only.

## Data flow (sentence lifecycle)

1. SystemAudioCapture slices the tap PCM stream into a 160 ms f32 chunk →
   `ASREngine.push`.
2. Polling yields partials (HUD draft; transcript history untouched) or
   finals.
3. Finals append to `SentenceBuffer` with sample-accurate offsets.
4. A tier-1/2/3 boundary closes the sentence → immutable `Sentence`
   published (JP row) and enqueued for translation.
5. `TranslationQueue` resolves → translation published (translated row)
   and appended to the in-memory session.
6. On Stop: capture stops, engine finish/drain, translation queue drains
   (bounded); the session becomes exportable.

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
        // language), stamped with its lane engine:
        // { "lang": "en", "text": "…", "engine": "deepl" }
      ]
    }
  ]
}
```

Invariants: consumers read languages from fields (never assume); a row
carries at most one translation per language — a re-translate replaces
its language's entry in place, it never appends; `schema_version` governs
evolution; sentence `index` is stable and keys JP↔translation alignment.

A translation entry may carry an optional `engine` field — the engine that
produced it via a manual row re-translate through an engine other than the
session engine (`appleFast` / `appleHighFidelity` / `google` / `deepl` /
`openrouter`; only the high-fidelity model is gated to macOS 26.4+ — the
fast-model lane exists on every supported OS, and is a genuine alternate
while an external engine is live). Session-engine results never carry
the field (absent = the session engine, never manually retried), so old
documents and fresh live-captions-only sessions are byte-identical; the
field is additive under schema v1. Whether retried rows also show the
engine inline in the UI is a Settings toggle (`translation.retranslateMarker`,
default on).

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
      (Assets.car, README.txt, THIRD_PARTY_NOTICES.txt, LICENSE.txt)
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
| Apple Translation framework | Platform | macOS 15+, on-device; high-fidelity (Apple Intelligence) strategy on 26.4+ |
| Core Audio process tap | Platform | macOS 15+; requires system-audio recording permission |

Compatibility: Apple Silicon, macOS 15.5+.

## Latency budget (expected)

| Stage | Cost |
|---|---|
| ASR chunk (algorithmic) | 160 ms fixed |
| Partial decode | step-spaced (1 s) window decodes; fast on the non-AR backends (Lite's SenseVoice: hundreds of ms; Full's FunASR ~4–5× slower but still real-time) |
| Sentence close + translation | ~2–4 s after sentence end |
| **End-to-end vs. live** | **multi-second** (dominated by decode latency + sentence completion) |
