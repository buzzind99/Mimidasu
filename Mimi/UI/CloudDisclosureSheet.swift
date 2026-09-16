import SwiftUI

/// Confirmation shown whenever a cloud translation provider is about to
/// become active (held selection in `AppModel.pendingCloudDisclosure`):
/// states plainly that transcript sentences will be sent to the chosen
/// provider over the internet, so the app's local-processing claim stays
/// accurate about its behavior. Confirming completes the selection;
/// declining leaves the current provider active. There is no persisted
/// acknowledgment — the sheet is raised on every switch to an external
/// provider.
struct CloudDisclosureSheet: View {
    let provider: TranslationProvider
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            KickerLabel("PRIVACY", color: Palette.label)
            Text("Translate with \(provider.displayName)?")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.primaryText)
            Text(
                "Sentences transcribed from your Mac's audio will be sent to "
                    + "\(provider.displayName) over the internet to be translated. "
                    + "Transcription and the default on-device translation always stay on this Mac."
            )
            .font(.system(size: 12))
            .foregroundStyle(Palette.secondaryText)
            HStack(spacing: 10) {
                Spacer()
                SettingsPill(label: "Cancel") {
                    model.declineCloudDisclosure()
                }
                SettingsPill(label: "Use \(provider.shortName)", prominent: true) {
                    model.confirmCloudDisclosure()
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Palette.window)
    }
}
