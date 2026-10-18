import SwiftUI

/// Confirmation shown whenever a cloud translation provider is about to
/// become active — as the live session engine (provider switch) or as the
/// re-translate engine (held intent in `AppModel.providerAwaitingDisclosure`):
/// states plainly what will be sent to the chosen provider over the
/// internet, so the app's local-processing claim stays accurate about its
/// behavior. The copy is intent-aware — a re-translate intent sends only
/// explicitly retried lines and leaves the live engine alone, and saying
/// "sentences will be sent" would read as a provider switch. There is no
/// persisted acknowledgment — the sheet is raised on every selection of an
/// external provider, either kind.
struct CloudDisclosureSheet: View {
    let intent: PendingCloudDisclosure
    /// The sentences an archive bulk run would send — the intent's count
    /// line. Nil for the settings intents (the copy carries no count).
    var sentenceCount: Int?
    let onConfirm: () -> Void
    let onDecline: () -> Void

    private var provider: TranslationProvider {
        intent.provider
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            KickerLabel("PRIVACY", color: Palette.label)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.primaryText)
            Text(bodyText)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
            HStack(spacing: 10) {
                Spacer()
                SettingsPill(label: "Cancel") {
                    onDecline()
                }
                SettingsPill(label: confirmLabel, prominent: true) {
                    onConfirm()
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Palette.window)
    }

    private var title: String {
        switch intent {
        case .providerSwitch:
            "Translate with \(provider.displayName)?"
        case .retranslateEngine:
            "Retry translations with \(provider.displayName)?"
        case .archiveTranslation:
            "Send text to \(provider.displayName)?"
        }
    }

    private var bodyText: String {
        switch intent {
        case .providerSwitch:
            "Sentences transcribed from your Mac's audio will be sent to "
                + "\(provider.displayName) over the internet to be translated. "
        case .retranslateEngine:
            "Lines you explicitly re-translate will be sent to "
                + "\(provider.displayName) over the internet to be translated. "
                + "The live translation engine is unchanged. "
        case .archiveTranslation:
            if let sentenceCount {
                "\(sentenceCount) sentences will be sent from your Mac to "
                    + "\(provider.displayName) for translation."
            } else {
                "Sentences will be sent from your Mac to \(provider.displayName) "
                    + "for translation."
            }
        }
    }

    private var confirmLabel: String {
        switch intent {
        case .providerSwitch, .retranslateEngine:
            "Use \(provider.shortName)"
        case .archiveTranslation:
            "Continue"
        }
    }
}
