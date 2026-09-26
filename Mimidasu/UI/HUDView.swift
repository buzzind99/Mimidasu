import SwiftUI

/// Floating HUD content: the in-flight JP partial on top, the displayed
/// translated entry (JP + EN) below. Hosted by `HUDHostingView` inside
/// `HUDPanel` (HUDWindow.swift).
struct HUDView: View {
    var model: AppModel
    var live: LivePartialState
    @ObservedObject var panel: HUDPanel
    @AppStorage(ReadingAnnotation.storageKey) private var readingAnnotation = ReadingAnnotation.romaji
    @AppStorage(CursorMode.storageKey) private var cursorMode = CursorMode.none
    @AppStorage(UIScale.storageKey) private var uiScale = UIScale.default

    /// Set on offscreen measurement copies: fixes the layout width so the
    /// measured ideal height reflects text wrapped at the real HUD width.
    var fixedWidth: CGFloat?

    var body: some View {
        if let fixedWidth {
            hudContent.frame(width: fixedWidth, alignment: .topLeading)
        } else {
            hudContent
        }
    }

    private var hudContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            liveSection
                .padding(.bottom, 8)
            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(height: 1)
                .padding(.bottom, 8)
            completedSection
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .cardSurface(
            radius: 12,
            fill: .black.opacity(0.62),
            stroke: .white.opacity(panel.locked ? 0.08 : 0.35)
        )
        .frame(minWidth: 360, minHeight: 170)
        .overlay(alignment: .topTrailing) { headerButtons }
    }

    /// Top-trailing row: translation-overlay toggle, padlock outermost.
    /// HUDHostingView.unlockRegion mirrors this rect so both buttons stay
    /// clickable while locked.
    private var headerButtons: some View {
        HStack(spacing: 6) {
            translationOverlayButton
            padlockButton
        }
        .padding(6)
    }

    /// Shows/hides the translation-only companion overlay; tinted with the
    /// translation color while the overlay is on screen.
    private var translationOverlayButton: some View {
        Button {
            model.translationOverlayVisible.toggle()
        } label: {
            Image(systemName: "translate")
                .font(.system(size: 10))
                .foregroundStyle(
                    model.translationOverlayVisible ? Theme.translationTeal : .secondary
                )
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show or hide the translation-only overlay")
    }

    private var padlockButton: some View {
        Button {
            panel.locked.toggle()
        } label: {
            Image(systemName: panel.locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(panel.locked ? "Unlock to move/resize (HUD is click-through when locked)" : "Lock (click-through)")
    }

    private var liveSection: some View {
        Group {
            if !live.partial.isEmpty {
                // RubyTextView renders .none as plain text, so one call
                // covers every annotation mode.
                RubyTextView(
                    text: live.partial,
                    annotation: readingAnnotation,
                    surfaceFont: .system(size: 22 * uiScale.factor, weight: .medium),
                    annotationFont: .system(size: 13 * uiScale.factor, design: .monospaced),
                    furiganaFont: .system(size: 15 * uiScale.factor, design: .monospaced),
                    annotationColor: Theme.hudAnnotation,
                    reservesAnnotationLine: true,
                    // Growing partial revisions never repeat — don't churn
                    // the annotator cache with them.
                    cachesSegments: false
                )
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Listening…")
                    .font(.system(size: 13 * uiScale.factor))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
    }

    /// Translated entries only; finalized-but-untranslated sentences never
    /// enter the cycle (the view doesn't move until their translation lands).
    private var translatedEntries: [SessionEntry] {
        model.entries.filter { entry in entry.joinedTranslations != nil }
    }

    private var completedSection: some View {
        Group {
            let entries = translatedEntries
            if entries.isEmpty {
                Text("Waiting for the first sentence…")
                    .font(.system(size: 13 * uiScale.factor))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(alignment: .center, spacing: 6) {
                    entryView(displayedEntry(in: entries))
                    historyButtons(entries: entries)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The pinned entry while browsing history; otherwise (nil pin, or a pin
    /// that no longer resolves) the latest translated entry. Scans
    /// newest-first: sentence indexes grow monotonically, so the match —
    /// the newest entry in the common no-pin case — sits at the tail.
    private func displayedEntry(in entries: [SessionEntry]) -> SessionEntry {
        guard let index = HUDHistory.displayedIndex(in: entries, pinned: model.hudPinnedIndex) else {
            return entries[entries.count - 1]
        }
        return entries.last(where: { entry in entry.sentence.index == index })
            ?? entries[entries.count - 1]
    }

    private func entryView(_ entry: SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if readingAnnotation != .none {
                Text(SessionClock.timestamp(entry.sentence.startS))
                    .font(ScaledFont.caption(uiScale.factor).monospacedDigit())
                    .foregroundStyle(Theme.hudTimestamp)
                jpText(of: entry)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(SessionClock.timestamp(entry.sentence.startS))
                        .font(ScaledFont.caption(uiScale.factor).monospacedDigit())
                        .foregroundStyle(Theme.hudTimestamp)
                    jpText(of: entry)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let en = entry.joinedTranslations {
                Text(en)
                    .font(.system(size: 13 * uiScale.factor))
                    .foregroundStyle(.teal)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Shared JP text call (RubyTextView renders .none as plain text).
    private func jpText(of entry: SessionEntry) -> some View {
        RubyTextView(
            text: entry.sentence.text,
            annotation: readingAnnotation,
            surfaceFont: .system(size: 14 * uiScale.factor),
            annotationFont: .system(size: 11 * uiScale.factor, design: .monospaced),
            furiganaFont: .system(size: 11 * uiScale.factor, design: .monospaced),
            annotationColor: Theme.hudAnnotation,
            cursorMode: cursorMode,
            onCopy: { text in model.copySnippet(text) }
        )
        .foregroundStyle(.white)
    }

    /// Right-side history stack, vertically centered against the entry.
    /// Down = newer (disabled at latest, so the cursor follows new
    /// translations); up = older (pins to that exact sentence, so new
    /// translations never move the view). Double chevrons jump to the ends:
    /// oldest (pins the first entry) and newest (clears the pin, re-follows
    /// latest).
    private func historyButtons(entries: [SessionEntry]) -> some View {
        VStack(spacing: 2) {
            historyButton(
                icon: "chevron.up.2",
                help: "Oldest translation",
                disabled: !HUDHistory.canJumpToOldest(entries: entries, pinned: model.hudPinnedIndex)
            ) {
                model.hudPinnedIndex = entries.first?.sentence.index
            }
            historyButton(
                icon: "chevron.up",
                help: "Older translation",
                disabled: !HUDHistory.canStepOlder(entries: entries, pinned: model.hudPinnedIndex)
            ) {
                cycleHistory(entries: entries, step: -1)
            }
            historyButton(
                icon: "chevron.down",
                help: "Newer translation",
                disabled: !HUDHistory.canStepNewer(entries: entries, pinned: model.hudPinnedIndex)
            ) {
                cycleHistory(entries: entries, step: 1)
            }
            historyButton(
                icon: "chevron.down.2",
                help: "Newest translation",
                disabled: !HUDHistory.canJumpToNewest(entries: entries, pinned: model.hudPinnedIndex)
            ) {
                model.hudPinnedIndex = nil
            }
        }
    }

    /// Steps the pin one translated entry up/down. Stepping onto the newest
    /// entry clears the pin (re-follows latest, re-disabling up).
    private func cycleHistory(entries: [SessionEntry], step: Int) {
        model.hudPinnedIndex = HUDHistory.cycle(
            entries: entries, pinned: model.hudPinnedIndex, step: step
        )
    }

    private func historyButton(
        icon: String, help: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(disabled ? .tertiary : .secondary)
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}
