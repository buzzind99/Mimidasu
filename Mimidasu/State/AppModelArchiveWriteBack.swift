import Foundation

// The single write-back seam every landed translation funnels through —
// per-row re-translate, bulk runs, and the live recording alike: one store
// upsert, one conditional refresh of the opened archive's languages, one
// revision bump, one landed report. Callers keep their row swaps and their
// own warning policies (archive-mode cards closable; the live latch
// persistent).

extension AppModel {
    /// The one shared body for a translation whose store write was lost —
    /// the archive-mode card's copy. The live latch names its own, wider
    /// consequence instead.
    static let lostTranslationWriteWarning =
        "The session store couldn't be written to. "
            + "This translation wasn't added to the archive."

    /// Writes one landed translation through to `session`: the store upsert
    /// first; on a landed write the opened archive's language payload
    /// refreshes when the write targeted it, then the revision bumps.
    /// Reports whether the write landed — a lost write changes nothing (no
    /// refresh, no bump), and the caller's policy decides the warning and
    /// whether its row keeps its previous text.
    @discardableResult
    func writeBackTranslation(
        _ translation: SentenceTranslation, index: Int, session: Int64
    ) -> Bool {
        guard archive.upsert(translation: translation, index: index, session: session) else {
            return false
        }
        if openArchive?.id == session {
            refreshOpenArchiveLanguages()
        }
        archiveRevision &+= 1
        return true
    }
}
