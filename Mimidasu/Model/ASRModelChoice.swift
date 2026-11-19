import Foundation

/// Which ASR GGUF the app uses. Raw values are the UserDefaults payload
/// (`"asr.model"`), so they must stay stable.
enum ASRModelChoice: String, CaseIterable, Identifiable {
    /// SenseVoice-Small q8_0 — the default: small download, fast start.
    case lite
    /// Haas-ja-v1.0 q8_0 — mid-size model: near-Full accuracy at a fraction
    /// of the decode cost, so it sits between Lite and Full.
    case haas
    /// FunASR-Nano 2512 q8_0 — the original full model, kept for existing
    /// installs and as the largest accuracy reference.
    case full

    var id: String {
        rawValue
    }

    /// UI-facing name (Settings rows, onboarding cards).
    var displayName: String {
        switch self {
        case .lite: "Lite"
        case .haas: "Balanced"
        case .full: "Full"
        }
    }

    /// Underlying speech-model name (Settings row subtitle).
    var modelName: String {
        switch self {
        case .lite: "SenseVoice-Small"
        case .haas: "Haas-ja-v1.0"
        case .full: "FunASR-Nano-2512"
        }
    }

    /// GGUF file name inside the shared models directory (every choice lives
    /// side-by-side, so switching never re-downloads).
    var ggufFileName: String {
        switch self {
        case .lite: "sensevoice-small-q8_0.gguf"
        case .haas: "haas-ja-v1.0-q8_0.gguf"
        case .full: "funasr-nano-2512-q8_0.gguf"
        }
    }

    /// Hugging Face repo id — also the session-metadata `model` value.
    var modelID: String {
        switch self {
        case .lite: "sensevoice-small-GGUF"
        case .haas: "Haas-ja-v1.0-GGUF"
        case .full: "funasr-nano-GGUF"
        }
    }

    /// Upstream repo revision the download URL resolves against. Pinning a
    /// commit SHA (instead of `main`) keeps shipped builds on bytes that can
    /// never change: later upstream pushes only move `main`.
    var revision: String {
        switch self {
        case .lite: "e1ad67de9d05137a6a0b02beba1fd66e28df6ae4"
        case .haas: "607fa1450398d589643fbb0e8bb1d0424af68d11"
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
        case .haas:
            "630fb47ac99d5111b0f99a7488857405611f05d7acae0fb2ceba4847ae1f9a2c"
        case .full:
            "dac5e1b95659c0a95b2a1dc60083eb17740454a921ec39f9c24e50b930ca31ab"
        }
    }

    /// Approximate download size for UI copy.
    var approximateSize: String {
        switch self {
        case .lite: "~250 MB"
        case .haas: "~650 MB"
        case .full: "~1.2 GB"
        }
    }

    /// One-line tradeoff copy for the onboarding cards and Settings rows.
    var blurb: String {
        switch self {
        case .lite:
            "Smaller download & memory usage, faster inference — great default for everyday transcription. (Recommended)"
        case .haas:
            "Medium download & memory usage, near-Full accuracy with about 3.5× faster decoding — a strong balance for most Macs."
        case .full:
            "Largest download & memory usage, slowest inference — for potentially more accurate transcription."
        }
    }
}
