import Foundation

/// Which ASR GGUF the app uses. Raw values are the UserDefaults payload
/// (`"asr.model"`), so they must stay stable.
enum ASRModelChoice: String, CaseIterable, Identifiable {
    /// SenseVoice-Small q8_0 — the default: small download, fast start.
    case lite
    /// FunASR-Nano 2512 q8_0 — opt-in full model.
    case full

    var id: String {
        rawValue
    }

    /// UI-facing name (Settings rows, onboarding cards).
    var displayName: String {
        switch self {
        case .lite: "Lite"
        case .full: "Full"
        }
    }

    /// Underlying speech-model name (Settings row subtitle).
    var modelName: String {
        switch self {
        case .lite: "SenseVoice-Small"
        case .full: "FunASR-Nano-2512"
        }
    }

    /// GGUF file name inside the shared models directory (both choices live
    /// side-by-side, so switching never re-downloads).
    var ggufFileName: String {
        switch self {
        case .lite: "sensevoice-small-q8_0.gguf"
        case .full: "funasr-nano-2512-q8_0.gguf"
        }
    }

    /// Hugging Face repo id — also the session-metadata `model` value.
    var modelID: String {
        switch self {
        case .lite: "sensevoice-small-GGUF"
        case .full: "funasr-nano-GGUF"
        }
    }

    /// Upstream repo revision the download URL resolves against. Pinning a
    /// commit SHA (instead of `main`) keeps shipped builds on bytes that can
    /// never change: later upstream pushes only move `main`.
    var revision: String {
        switch self {
        case .lite: "e1ad67de9d05137a6a0b02beba1fd66e28df6ae4"
        case .full: "5d4346e47c268ba91a332a148a1fd39b766408ac"
        }
    }

    /// Hugging Face resolve URL for the pinned GGUF file.
    var downloadURL: URL {
        URL(string: "https://huggingface.co/cstr/\(modelID)/resolve/\(revision)/\(ggufFileName)")!
    }

    /// Pinned SHA-256 (release-time integrity check) — the Hugging Face LFS
    /// oid of the GGUF at the pinned revision.
    var pinnedSHA256: String {
        switch self {
        case .lite:
            "6b84003db9da214c129bcdbb1c471d25b211775a905aecb253dd23aebf18b7f4"
        case .full:
            "dac5e1b95659c0a95b2a1dc60083eb17740454a921ec39f9c24e50b930ca31ab"
        }
    }

    /// Approximate download size for UI copy.
    var approximateSize: String {
        switch self {
        case .lite: "~250 MB"
        case .full: "~1.2 GB"
        }
    }

    /// One-line tradeoff copy for the onboarding cards and Settings rows.
    var blurb: String {
        switch self {
        case .lite:
            "Smaller download & memory usage, faster inference — great default for everyday transcription. (Recommended)"
        case .full:
            "Larger download & memory usage, slower inference — for potentially more accurate transcription."
        }
    }
}
