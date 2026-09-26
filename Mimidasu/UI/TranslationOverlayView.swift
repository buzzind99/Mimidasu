import SwiftUI

/// Translation-only overlay content: a scrollable, bottom-pinned list of
/// every finalized translation (timestamp + EN text), hosted by
/// `TranslationOverlayHostingView` inside `TranslationOverlayPanel`
/// (TranslationOverlayWindow.swift). Scroll behavior mirrors
/// `TranscriptView` via the shared `PinnedScrollModel`.
struct TranslationOverlayView: View {
    var model: AppModel
    @ObservedObject var panel: TranslationOverlayPanel
    @AppStorage(UIScale.storageKey) private var uiScale = UIScale.default

    static let topAnchorID = "translation-overlay-top-anchor"
    static let bottomAnchorID = "translation-overlay-bottom-anchor"

    /// Scroll state held out of the body, same split as the transcript:
    /// per-tick geometry writes land on the model, never on this view's
    /// graph.
    @State private var scroll = PinnedScrollModel(
        topAnchorID: TranslationOverlayView.topAnchorID,
        bottomAnchorID: TranslationOverlayView.bottomAnchorID
    )

    var body: some View {
        ScrollViewReader { proxy in
            // Translation list fills the left; the jump buttons live in
            // their own right-side column so they never sit on top of the
            // text.
            HStack(alignment: .bottom, spacing: 0) {
                List {
                    Color.clear
                        .frame(height: 1)
                        .padding(.top, 16)
                        .id(Self.topAnchorID)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    if translatedEntries.isEmpty {
                        emptyState
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(translatedEntries) { entry in
                        row(for: entry)
                            .id(entry.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    Color.clear
                        .frame(height: 1)
                        .padding(.bottom, 12)
                        .id(Self.bottomAnchorID)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // The bottom marker row is 1pt tall; without this List
                // enforces a minimum row height that would keep it from
                // sitting flush.
                .environment(\.defaultMinListRowHeight, 1)
                .onScrollGeometryChange(for: TranscriptScrollPin.Snapshot.self) { geometry in
                    TranscriptScrollPin.Snapshot(
                        offsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height,
                        insetTop: geometry.contentInsets.top,
                        insetBottom: geometry.contentInsets.bottom
                    )
                } action: { old, new in
                    scroll.handle(old: old, new: new, proxy: proxy)
                }
                .onChange(of: model.entries) { _, _ in
                    // Covers appends and rows growing when a translation lands.
                    scroll.reAnchor(proxy)
                }
                .onChange(of: uiScale) { _, _ in
                    // Scaling resizes every row; re-anchor if pinned.
                    scroll.reAnchor(proxy)
                }
                .onAppear {
                    // List has no `.initialOffset` anchor (ScrollView-only);
                    // start pinned at the newest translation.
                    scroll.reAnchor(proxy)
                }

                ScrollJumpButtons(scroll: scroll, proxy: proxy, glyphColor: .secondary)
                    .padding(.trailing, 10)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardSurface(
            radius: 12,
            fill: .black.opacity(0.62),
            stroke: .white.opacity(panel.locked ? 0.08 : 0.35)
        )
        .frame(minWidth: 280, minHeight: 200)
        .overlay(alignment: .topTrailing) { headerButtons }
    }

    /// Translated entries only; finalized-but-untranslated sentences never
    /// enter the list (each row's text lands with its translation).
    private var translatedEntries: [SessionEntry] {
        model.entries.filter { entry in entry.joinedTranslations != nil }
    }

    private var emptyState: some View {
        Text("Waiting for the first translation…")
            .font(.system(size: 13 * uiScale.factor))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 32)
    }

    private func row(for entry: SessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(SessionClock.timestamp(entry.sentence.startS))
                .font(ScaledFont.caption(uiScale.factor).monospacedDigit())
                .foregroundStyle(Theme.hudTimestamp)
            if let en = entry.joinedTranslations {
                Text(en)
                    .font(.system(size: 13 * uiScale.factor))
                    .foregroundStyle(.teal)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.bottom, 12)
    }

    /// Top-trailing pair: padlock, then the close button outermost.
    /// `TranslationOverlayHostingView.buttonRegion` mirrors this row so
    /// both stay clickable while locked.
    private var headerButtons: some View {
        HStack(spacing: 6) {
            padlockButton
            closeButton
        }
        .padding(6)
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
        .help(
            panel.locked
                ? "Unlock to move/resize (overlay is click-through when locked)"
                : "Lock (click-through)"
        )
    }

    private var closeButton: some View {
        Button {
            model.translationOverlayVisible = false
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide translation overlay")
    }
}
