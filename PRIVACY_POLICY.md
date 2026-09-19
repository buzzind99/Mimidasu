# Mimidasu Privacy Policy

**Effective date: September 19, 2026**

Mimidasu is a macOS application that transcribes Japanese system audio in real
time and translates it to English. It is designed so that your data stays
on your machine. This policy explains exactly what the app does and does
not do with your data.

**Short version: Mimidasu collects no data. Nothing about you, your audio, or
your transcripts is ever sent to the developer — there are no servers, no
analytics, no tracking, and no accounts.**

## What the app captures

With your explicit grant of system-audio recording permission in System
Settings, Mimidasu captures **system audio only** — no microphone input and no
screen images — using a Core Audio process tap. The audio exists solely in
app memory for the purpose of live transcription:

- Audio is processed entirely **on your device**.
- Audio is never uploaded, and Mimidasu does not save audio or video
  recordings to disk.
- You can revoke permission at any time in **System Settings → Privacy &
  Security → Screen & System Audio Recording**

## Speech transcription

Transcription runs **on your device** using a local speech-recognition
model. To make that possible, Mimidasu downloads a publicly available open
model file from **Hugging Face** (huggingface.co) on first launch. That
download is a plain HTTPS file request for the model file only — it contains
no audio, transcripts, or identifiers in the request payload. Like any HTTPS
download, standard network-level metadata (such as your IP address) is
visible to Hugging Face and its content-delivery network during the transfer.
The download is verified against a pinned checksum before use.

## Translation

- By default, translation uses Apple's **on-device Translation
  framework**: the text never leaves your machine. Using it may download
  language packs from Apple; that transfer is between your device and Apple
  under Apple's privacy policy.
- Optionally, you can connect a cloud translation provider — Google
  Translate, DeepL, or OpenRouter — using **your own API key**. When you
  do, finalized transcript **text sentences only** (no audio) are sent over
  HTTPS **directly from your device to that provider** to be translated.
  The developer receives none of it. The app asks for your explicit
  confirmation the first time you enable a cloud provider. Before enabling
  one, please review that provider's privacy policy:
  - Google Cloud Privacy Notice: https://cloud.google.com/terms/cloud-privacy-notice
  - DeepL Privacy Policy: https://www.deepl.com/privacy
  - OpenRouter Privacy Policy: https://openrouter.ai/privacy
- Your provider API key is stored in your Mac's **Keychain** on your
  device. It is shared only with the provider you chose, as
  authentication, and is never transmitted to the developer or to any
  developer-operated server.

## What is stored, and where

All storage is local to your Mac:

- **Session transcripts and exports** are files you create and control
  through the standard save/export dialogs.
- **Settings and preferences** are stored in the app's local preferences.
- **API keys** for optional cloud providers are stored in your Keychain.
- **The downloaded ASR model and its checksum record** are cached in the
  app's Application Support folder. **Dictionary data** ships inside the
  app itself and is extracted to Application Support on first launch, so
  the app works offline after setup.

## Data the developer collects

**None.** Mimidasu has no telemetry, crash reporting, analytics, advertising,
user accounts, or developer-operated servers of any kind. The app's
privacy manifest declares no tracking and no collected data types. If the
app was installed from the Mac App Store and you choose to send crash
reports or diagnostics to Apple, that data goes to Apple under Apple's
privacy policy.

## Third-party components

Mimidasu bundles open-source components licensed by their respective authors.
Their notices are included with the app in `THIRD_PARTY_NOTICES.txt`.

## Changes to this policy

If the app's data practices ever change, this policy will be updated and
the effective date at the top will change with it.

## Contact

Questions about this policy: please open an issue at
https://github.com/buzzind99/Mimidasu/issues
Or email: buzzind99@gmail.com
