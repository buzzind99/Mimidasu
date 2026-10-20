import SwiftUI

/// The stop confirmation, attached once to the main window root — the sidebar
/// capsule files the request (`AppModel.shouldConfirmStop` is the policy) and
/// the window presents it, so the wording lives in one place. Cancel keeps
/// the session live; Stop is the single action, in the stop red — there is no
/// Save & Stop. The session finalizes as a Recent either way.
struct StopConfirmation: ViewModifier {
    let model: AppModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert("Stop the session?", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Stop", role: .destructive) { model.stop() }
        } message: {
            Text(
                "This session will be kept in Recent — only the last 10 unsaved "
                    + "sessions are kept. Save it permanently later from the archive window."
            )
        }
    }
}

/// The close-the-archive-and-start confirmation. Start is never refused
/// outright while an archived session is open or a bulk translation is
/// running — it asks first; confirm stops any run, closes the archive, and
/// starts; Cancel changes nothing.
struct ArchiveStartConfirmation: ViewModifier {
    let model: AppModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        let jobRunning = model.archiveTranslationRunning
        content.alert(
            Text(
                jobRunning
                    ? "Stop the translation and start a new session?"
                    : "Close the archive and start a new session?"
            ),
            isPresented: $isPresented
        ) {
            Button("Cancel", role: .cancel) {}
            if jobRunning {
                Button("Stop translation and start") {
                    model.cancelArchiveTranslation()
                    model.closeArchive()
                    model.start()
                }
            } else {
                Button("Start session") {
                    model.closeArchive()
                    model.start()
                }
            }
        } message: {
            Text(
                jobRunning
                    ? "A batch translation is still running. Starting a new session stops it — translations already finished are kept."
                    : "The archived session stays in the archive; the transcript pane empties."
            )
        }
    }
}

extension View {
    func stopConfirmation(_ model: AppModel, isPresented: Binding<Bool>) -> some View {
        modifier(StopConfirmation(model: model, isPresented: isPresented))
    }

    func archiveStartConfirmation(_ model: AppModel, isPresented: Binding<Bool>) -> some View {
        modifier(ArchiveStartConfirmation(model: model, isPresented: isPresented))
    }
}
