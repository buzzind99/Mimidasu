# Architecture

**Mimidasu** — a real-time Japanese livestream transcriber/translator for
macOS (Apple Silicon, 15.5+). Captures system audio via a Core Audio process
tap, streams it through a selectable ASR GGUF — **Lite** (SenseVoice-Small,
default) or **Full** (FunASR-Nano) — via the CrispASR runtime with
FireRedVAD endpointing, and translates finalized sentences to English with
Apple's on-device Translation framework or an optional cloud provider
(Google Translate, DeepL, OpenRouter) behind the same engine seam. Ruby
annotations (romaji/furigana) and tap-to-lookup dictionary entries come
from a bundled IPADIC tokenizer plus a pinned JMDict/JMnedict SQLite DB.

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
             │       TranslationQueue      │ Apple on-device (default) or
             │                             │ cloud provider, serialized
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
  rate changes rebuild the converter live.

### CrispASREngine (`ASR/`)
- Swift wrapper over dlopen'd `libcrispasr.dylib` (stable C session ABI;
  vendored headers in `native/include/crispasr/`). The backend
  (`sensevoice` / `funasr`) is detected from the GGUF header — a property
  of the chosen model, not the build.
- The backends have no cache-aware streaming, so the sliding window lives
  in Swift: a rolling utterance buffer (12 s forced-final cap) plus a 10 s
  window for partial decodes.
- **FireRedVAD** runs every 500 ms on its own queue and is the
  authoritative speech signal: it gates partial decodes, finalizes an
  utterance after ~800 ms of confirmed silence, and speechless buffers are
  discarded without decoding. A cheap per-chunk RMS check is only a
  backstop (and covers degraded mode when the VAD model is unavailable).
- 1 s-step window decodes post `.partial` (HUD draft); the endpoint
  redecodes the buffered utterance PCM and posts one clean `.final`.
- Lifecycle: `prepare` (dlsym + GPU backend + session open) → `openStream`
  → `push` per chunk → `poll` from a 60 ms timer → `finish` (drain + final
  flush) → session close. Decodes run on a dedicated serial queue so
  `poll` never blocks behind a multi-second decode; teardown is strictly
  ordered (capture stop → finish/drain → close).
- `ASREngine` protocol + factory: CrispASR when the runtime and model
  resolve, otherwise the labeled mock transcriber.

### SentenceBuffer (`Session/`)
- Streaming ja ASR routinely drops punctuation, so boundaries are 3-tier:
  1. Terminal punctuation (`。！？`) closes immediately.
  2. No new finals for ~1 s finalizes the buffer.
  3. ~35–45 char cap, split at the nearest clause boundary (`、` or
     `けど` / `から` / `ので` / `って`).
  Symbol-only finals (e.g. `...`) never start a sentence.
- Timestamps from the session sample clock (chunk offsets ÷ 16 kHz): each
  sentence records `start_s`/`end_s`, ±160 ms granularity. Partials are
  never stamped.
- Output: immutable `Sentence` `{index, start_s, end_s, lang, transcript}`
  published to UI state and queued for translation.

### Translation (`Translation/`)
- **Seam:** `TranslationEngine` — ordered batch `translate`, `preferredBatchSize`,
  optional `onRetry`, typed error taxonomy. `TranslationQueue.run(with:)`
  accepts any engine; `Translation/Providers/` holds the cloud adapters.
- **Engines:** Apple on-device (`AppleSessionEngine` over SwiftUI's
  `.translationTask`; the default; OS prompts a one-time language pack) and
  Google Translate, DeepL, OpenRouter (chat completions with a strict JSON
  array prompt, parsed leniently). Language pair fixed ja→en. A configured
  external provider becomes active at the next session start.
- **Queue:** strictly serialized `@MainActor` worker; untranslated
  sentences live in a plain array that survives cancellation; a generation
  token retires cancelled runs; repeats are served from a cache; empty
  finals dropped at enqueue. On stop the queue drains with a 5 s bound so
  the session stays exportable.
- **Retry ladder:** transient failures (429 / 5xx / network) retry twice
  with backoff, honoring a capped `Retry-After`; invalid key, quota, and
  malformed output fail fast. Settings' Test probes run zero-retry.
- **Failure ladder:** exhausted external errors latch Apple on-device for
  the rest of the session (one-way per session; `.degraded` published; the
  footer's manual Retry re-attempts the external engine). An unconfigured
  provider falls back to Apple with a status note.
- **Keys:** `KeychainStore` (`Security/`, device-only accessibility);
  key material never reaches UserDefaults, logs, error strings, or export
  files — the settings store persists non-secrets only.
- **Disclosure:** activating any cloud provider requires confirming
  `CloudDisclosureSheet` ("sentences will be sent to \<provider\>"), raised
  on every switch to an external provider; audio itself never leaves the
  machine.
- **Status surface:** `TranslationPill.map(status:activeEngine:)` derives
  the pill/card dot tone; the sidebar detail line mirrors state
  ("On-device (fallback)", "Unavailable", provider name); retry/fallback/
  unavailable states surface as toasts.

### Reading annotation & dictionary lookup (`Text/`, `Dictionary/`)
- **Annotator:** `ReadingAnnotator` tokenizes via `DictionaryEngine`
  (dlopen'd `libdictionary.dylib`, bundled IPADIC) and emits segments
  `{surface, romaji, furigana, lemma, pos}` — one segmentation feeds both
  annotation modes. Romaji derives from kana readings (Hepburn consonants,
  wapuro long vowels) with particle overrides (は/へ/を → wa/e/o), lexical
  spellings, numeral→counter fusion (`600回` → "roppyakkai"), and
  sokuon-span merging (`言って` → one segment). Furigana covers only kanji,
  aligned by walking the kana reading through the surface; tokens carry a
  curated reading per inflected surface, so conjugated forms annotate
  without re-inflection.
- **Reading fallback:** kanji surfaces the tokenizer leaves reading-less
  consult JMDict's reading index, behind a miss-caching NSCache. Surfaces
  that survive both (names, rare ideographs, bare Latin) render
  self-transcribed and unannotated.
- **Fail-soft:** a missing dylib or model means plain runs that still
  concatenate back to the original; preparation retries next launch.
- **Lookup data:** pinned JMDict_Extended (`1.4.1-auto-release-2026-09-01`)
  + JMnedict (`3.6.2+20260914172325`). The pins live in
  `Dictionary/JMDictPin.swift` and are asserted by
  `scripts/build_dictionary.sh`, whose format probe hard-fails on upstream
  drift. Both sources build into one `jmdict-<tag>.sqlite`
  (entries/senses/headwords/meta — no FTS, exact `headwords.text` hits);
  JMnedict names ride `ent_seq + 10M` in the same tables. The DB bundles
  as `jmdict-<tag>.sqlite.zst` — the tag is the staleness key, stale
  prepared artifacts are swept. Both DBs decompress once to
  Application Support on first launch (offline, smoke-checked).
- **Lookup engine:** `JMDictLookup` — typed errors (no-hit ≠ infrastructure
  failure), all homograph entries returned ranked common-first, sense
  restriction filters honored. `JMDictExpansion` walks forward from the
  tapped segment joining ≤3 candidates (lemma preferred over surface),
  validated against the sentence's render text (drift fails closed; the
  tapped segment still queries).
- **Tap surface:** cursor modes None / Dictionary / Copy. A tap resolves
  through the pipeline and pins the sidebar DICTIONARY card plus a popover
  anchored at the word; homograph entries walk via the `◀ i/N ▶` pager,
  fallback hits surface as capped "also:" pills (JOINED MATCH badge for
  forward-join leads), a bare miss posts the amber notice pill, and an
  infrastructure failure posts a toast. Name entries render type badges
  (SURNAME / GIVEN NAME / PLACE NAME / …) and drop the romanization-echo
  gloss.

### Model choice (`Model/`)
- `ASRModelChoice` — `.lite` / `.full`, each carrying its metadata (GGUF
  name, HF repo, pinned SHA-256, size, tradeoff copy): Lite =
  `sensevoice-small-q8_0.gguf` (~250 MB, default), Full =
  `funasr-nano-2512-q8_0.gguf` (~1.2 GB). Selection persists to
  UserDefaults key `"asr.model"`.
- Resolution per choice: `Bundle.main` →
  `~/Library/Application Support/Mimidasu/models/` → dev checkout.
  `ModelVerifier` checks the pinned SHA-256 (path+size verdict cache, so
  switching never re-hashes the other model); `ModelDownloader` handles
  resume / cancel / verify-and-replace.
- A model must be downloaded **and verified** before selection; a
  mid-session switch applies at next session start; completing a Settings
  download auto-selects (the path-keyed engine cache retires the old
  engine). No resolvable model → the labeled mock transcriber.

### AppModel + SessionController (`State/`, `Session/`)
- `AppModel` (@MainActor `@Observable`): session phase, transcript
  entries, translation status, HUD pin, toast/notice stacks, audio level +
  latency, ASR model state, lookup state (popover + pinned card), and the
  `TranslationSession.Configuration` driving `.translationTask`. Split
  into extensions (`AppModelTranslation` / `Export` / `Dictionary` /
  `Lookup`). Injectable test seams: a scripted `SessionController`, a
  stubbed model resolver, the terminate-notification center, and the HTTP
  translation transport.
- `SessionController`: engine creation via `ASREngineFactory` + background
  warm-up, capture wiring, the sentence buffer, the 60 ms poll / 200 ms
  tick timers, ASR event → sentence handling, mid-session capture restart
  (no model reload), and strictly ordered teardown (capture stop → engine
  finish/drain → timers → buffer flush → bounded translation drain). A
  one-shot silence watchdog surfaces a no-audio warning when a fresh
  capture stays below the silence floor; the first audible signal retires
  it.

### UI (`UI/`, SwiftUI `@MainActor`)
- **Main window:** fixed sidebar (session capsule, READING AIDS + CURSOR
  pickers, ENGINES / AUDIO / SESSION / DICTIONARY cards, toolbar) beside a
  virtualized transcript (gutter timestamps, `RubyTextView` JP, teal EN
  translation, circular jump buttons) with the live partial strip pinned
  under it. The toast stack overlays the transcript pane.
- **State split:** high-frequency partials (`LivePartialState`), the audio
  level ring (`AudioLevelState`), and latency (`LatencyState`) are small
  standalone observables, so partial-rate updates never re-render the
  transcript.
- **Floating HUD:** always-on-top, semi-transparent, click-through,
  resizable; up/down chevrons step its pin through translated entries
  (stepping to the newest clears the pin and re-follows).
- **Toasts & notices:** `ToastCenter` — deduped, capped stack of warning/
  error cards (persistent red cards carry a fix action: Restart, Retry);
  cleared on session teardown. `NoticeCenter` — a single transient pill
  (teal confirmations like "Text copied", amber dictionary no-hit), 2 s
  auto-dismiss.
- **Theming:** `Theme.swift` centralizes tokens (dark values from the
  mock, derived light variant); `AppearanceSetting` (system/light/dark)
  applies via `.preferredColorScheme`; reading-annotation and cursor
  settings are `DynamicProperty` wrappers. `RubyTextView` renders inline
  romaji or furigana; in dictionary mode with a host lookup handler it
  renders one tappable unit per segment.

### SessionExporter (`Export/`)
- Plain text (`HH:MM:SS  text`), SRT/VTT subtitles (comma vs dot ms
  delimiter), and the JSON session file (below). Languages are read from
  fields, never assumed; session metadata included.

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
5. `TranslationQueue` resolves → translation published (EN row) and
   appended to the in-memory session.
6. On Stop: capture stops, engine finish/drain, translation queue drains
   (bounded); the session becomes exportable.

## JSON session file (authoritative interchange format)

```jsonc
{
  "schema_version": 1,
  "session": {
    "started_at": "2026-08-27T14:32:05+09:00",
    "source_lang": "ja",           // null if ASR auto-detect
    "target_lang": "en",
    "model": "sensevoice-small-GGUF",   // the active choice's modelID
                                        // ("funasr-nano-GGUF" for full)
    "chunk_ms": 160,
    "stream_offset": null          // future player writes user-settable offset
  },
  "sentences": [
    {
      "index": 0,
      "start_s": 12.48,
      "end_s": 15.04,
      "lang": "ja",                // per-sentence
      "transcript": "今日はいい天気ですね。",
      "translations": [ { "lang": "en", "text": "Nice weather today, isn't it?" } ]
    }
  ]
}
```

Invariants: consumers read languages from fields (never assume);
`translations` is append-only; `schema_version` governs evolution;
sentence `index` is stable and keys JP↔EN alignment.

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
      jmdict-<tag>.sqlite.zst           # JMDict + JMnedict lookup DB,
                                        # versioned by pin tag
      (assets, README, THIRD_PARTY_NOTICES)
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
| Apple Translation framework | Platform | macOS 15+, on-device |
| Core Audio process tap | Platform | macOS 15+; requires system-audio recording permission |

Compatibility: Apple Silicon, macOS 15.5+.

## Latency budget (expected)

| Stage | Cost |
|---|---|
| ASR chunk (algorithmic) | 160 ms fixed |
| Partial decode | step-spaced (1 s) window decodes; fast on the non-AR backends (Lite's SenseVoice: hundreds of ms; Full's FunASR ~4–5× slower but still real-time) |
| Sentence close + translation | ~2–4 s after sentence end |
| **End-to-end vs. live** | **multi-second** (dominated by decode latency + sentence completion) |
