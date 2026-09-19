# Mimidasu

**Live English subtitles for anything Japanese on your Mac.**

Mimidasu listens to whatever your Mac is playing — a livestream, a video, a
voice chat — and turns the Japanese speech into English subtitles in real
time. No accounts, no uploads, no cloud: everything runs on your machine.

**The name is a pun.** 見出す (*miidasu*) is Japanese for "to spot, to
discover." Add one more ミ and the word gains an 耳 (*mimi*, ear): **ミミダス**
— *the ear that surfaces words*. Exactly what the app does; it even works as
a verb, because every definition popup is a little *mimidasu*.

<p align="center">
  <img src="debug/ss.png" alt="Mimidasu app screenshot" width="900">
</p>

## Level-up your Japanese listening

- **Understand while it happens** — sentences appear as they're spoken, with
  the English translation right under the Japanese
- **Private by design** — audio, transcription, and translation all stay
  on-device; nothing ever leaves your Mac unless you opt into a cloud
  translation provider
- **Learn as you watch** — toggle furigana or romaji over the transcript, and
  click any word for definitions, pitch accent, and JLPT level
- **Floating subtitles** — a click-through HUD overlays the video you're
  watching, so Mimidasu stays out of the way
- **Keep the transcript** — export any session as TXT, SRT, VTT, or JSON

## Requirements

- Apple Silicon Mac, macOS 15.5+

## Quick start (from source)

```bash
scripts/bootstrap.sh      # one-time setup
brew install cmake ninja  # build dependencies
scripts/build_all.sh      # builds the ASR runtime, tokenizer, and dictionaries
open Mimidasu.xcodeproj   # then ⌘R
```

On first launch you pick a speech model and it downloads automatically; press
**Start** and grant audio access when prompted.

## Development

- `scripts/test.sh` — tests + coverage (Swift Testing)
- `scripts/lint.sh` — swiftformat + swiftlint
- See `ARCHITECTURE.md` for design notes

## License

Mimidasu is Copyright (C) 2026 Aulia Sufian Adi.

- **Source code** (and any build distributed outside the Mac App Store):
  [GNU AGPL-3.0](LICENSE.md)
- **Mac App Store build**: governed by Apple's standard Licensed
  Application EULA — see [LICENSE-MAS.md](LICENSE-MAS.md)

Third-party components are documented in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
