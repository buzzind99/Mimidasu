import SwiftUI

/// Confirmation shown whenever a cloud translation provider is about to
/// become active — as the live session engine (provider switch) or as the
/// re-translate engine (held intent in `AppModel.providerAwaitingDisclosure`):
/// states plainly that transcript sentences will be sent to the chosen
/// provider over the internet, so the app's local-processing claim stays
/// accurate about its behavior. The sheet itself is intent-agnostic; the
/// completion closures dispatch on the held intent. There is no persisted
/// acknowledgment — the sheet is raised on every selection of an external
/// provider, either kind.
struct CloudDisclosureSheet: View {
    let provider: TranslationProvider
    let onConfirm: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            KickerLabel("PRIVACY", color: Palette.label)
            Text("Translate with \(provider.displayName)?")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.primaryText)
            Text(
                "Sentences transcribed from your Mac's audio will be sent to "
                    + "\(provider.displayName) over the internet to be translated. "
            )
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondaryText)
            HStack(spacing: 10) {
                Spacer()
                SettingsPill(label: "Cancel") {
                    onDecline()
                }
                SettingsPill(label: "Use \(provider.shortName)", prominent: true) {
                    onConfirm()
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Palette.window)
    }
}
