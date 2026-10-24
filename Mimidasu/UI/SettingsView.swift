import SwiftUI

/// The provider well shows exactly four full rows. Rows own a fixed height
/// so the fourth row cannot be clipped by text metrics, and the compact
/// spacing keeps the card from sprawling.
private enum ProviderListMetrics {
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 6
    static let visibleRows = 4
    static var viewportHeight: CGFloat {
        CGFloat(visibleRows) * rowHeight
            + CGFloat(visibleRows - 1) * rowSpacing
    }
}

/// App settings — "stacked cards" design: a single scrollable column of cards
/// (notice, provider, API key, appearance, ASR model, session) with no
/// navigation chrome. Buttons highlight pink on hover; appearance segments use
/// a neutral wash.
struct SettingsView: View {
    private static let writeReviewURLString = "https://apps.apple.com/app/id6813053867?action=write-review"

    @Bindable private var model: AppModel
    @Bindable private var settings: TranslationSettings
    @AppearanceSetting private var appearance
    @State private var keyDraft = ""
    @State private var keySaveFailed = false
    /// Edit buffer for the displayed provider's model field; committed to
    /// that provider's stored model only after a successful probe.
    @State private var modelDraft = ""
    /// An external provider being set up but not yet configured: its key
    /// card is shown, but the selection (checkmark) stays on the current
    /// provider until a key is saved and the connection test succeeds.
    @State private var pendingProvider: TranslationProvider?
    /// A configured external provider whose key is being verified before the
    /// selection may move to it (row click → live probe). Its row shows a
    /// checking spinner; a stale outcome (another row clicked mid-probe) is
    /// discarded.
    @State private var verifyingProvider: TranslationProvider?
    /// Serial for row verifications. `verifyingProvider` alone cannot keep
    /// two probes for the same provider apart (A → B → A), so every new
    /// verification and every cancellation bumps this and stale tasks bail.
    @State private var verificationSerial = 0

    /// The provider whose card (key entry + privacy notice) is displayed:
    /// the pending one while it's being configured, otherwise the selection.
    private var displayedProvider: TranslationProvider {
        pendingProvider ?? settings.selectedProvider
    }

    init(model: AppModel) {
        let settings = model.translationSettings
        _model = Bindable(wrappedValue: model)
        _settings = Bindable(wrappedValue: settings)
        _modelDraft = State(initialValue: settings.model(for: settings.selectedProvider))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            settingsDivider()
            ScrollView {
                cards
                    .padding(.vertical, 24)
            }
        }
        .frame(
            minWidth: 420, idealWidth: 460, maxWidth: 560,
            minHeight: 720, idealHeight: 800
        )
        .background(Palette.window)
        .preferredColorScheme($appearance.resolvedColorScheme)
        // A selection change applies immediately while a session is running:
        // the queue re-attaches the selected engine mid-drain (pending
        // sentences replay onto it). A row pick on a configured external
        // provider only stages the cloud disclosure; confirmation writes the
        // selection that lands here. The key card's verified save also lands
        // here. An in-flight row probe belongs to the superseded intent.
        .onChange(of: settings.selectedProvider) {
            pendingProvider = nil
            cancelVerification()
            // Any selection change — a confirmed switch, or a key removal
            // falling back to Apple — supersedes an in-flight probe's intent.
            model.noteTranslationProviderIntent()
            model.translationProviderDidChange()
        }
        // Drafts follow the provider whose card is on screen: switching
        // providers must never carry a pasted key across (and a model typed
        // for a pending provider must survive the moment it becomes the
        // selected one, when the displayed provider does not change).
        .onChange(of: displayedProvider) { _, provider in
            modelDraft = settings.model(for: provider)
            keyDraft = ""
            keySaveFailed = false
        }
        // The cloud-provider disclosure, raised whenever an external
        // activation is held in `providerAwaitingDisclosure` (a provider
        // switch or a re-translate engine selection); confirming completes
        // the held intent, dismissing either way clears the bound item.
        .sheet(item: settingsDisclosure) { disclosure in
            CloudDisclosureSheet(
                // The presented intent, not the live slot: if the slot is
                // clobbered while the sheet is up, confirming this sheet must
                // not apply the newer intent.
                intent: disclosure,
                onConfirm: { model.confirmCloudDisclosure(disclosure) },
                onDecline: { model.declineCloudDisclosure() }
            )
        }
        // The Settings scene keeps its window — and this view's @State —
        // cached after close, so transient card state survives a reopen and
        // the key card would come back stuck on the last-clicked pending
        // provider. Becoming key signals either a reopen (the window
        // auto-closes on resign-key) or the cloud-disclosure sheet's
        // present/dismiss cycle re-keying the window that never closed;
        // both need the same reset, so it runs either way — reset so the
        // card reflects the active provider again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow,
                  SettingsWindowController.isSettingsWindow(window)
            else { return }
            pendingProvider = nil
            cancelVerification()
            // The reset bumps the intent generation on both paths, which is
            // intended (confirm and decline each bump on their own when a
            // sheet resolves); stopping a probe started before the window
            // closed from staging a selection or raising a sheet after it is
            // the willClose decline's job — its bump lands at close and
            // covers completions that arrive while the window is shut.
            model.noteTranslationProviderIntent()
            keyDraft = ""
            keySaveFailed = false
            modelDraft = settings.model(for: settings.selectedProvider)
            // The cached window doesn't re-run `.task` on reopen; the
            // availability probe is a no-op once loaded anyway.
            Task { await model.appleTranslationAvailability.refreshIfNeeded() }
        }
        // Closing Settings resolves what the window held: a pending
        // disclosure is abandoned (it does not survive the close) and any
        // probe still airborne loses its intent when it completes. A
        // resign-key that does not close the window (a sheet is up) leaves
        // the sheet alone, so an app switch never drops live consent.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let window = note.object as? NSWindow,
                  SettingsWindowController.isSettingsWindow(window)
            else { return }
            model.declineCloudDisclosure()
        }
    }

    /// The shared disclosure slot, filtered to the settings intents: an
    /// archive bulk run's intent belongs to the main window's sheet and must
    /// never present here. Writing nil — the sheet's dismissal — declines the
    /// held slot; decline is idempotent.
    private var settingsDisclosure: Binding<PendingCloudDisclosure?> {
        Binding(
            get: {
                guard let pending = model.providerAwaitingDisclosure else { return nil }
                switch pending {
                case .providerSwitch, .retranslateEngine: return pending
                case .archiveTranslation: return nil
                }
            },
            set: { newValue in
                if newValue == nil {
                    model.declineCloudDisclosure()
                }
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(
                    LinearGradient(
                        colors: [Palette.accent, Palette.accentViolet],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
            Text("Settings")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Palette.primaryText)
            Spacer()
        }
        .padding(.leading, 52)
        .padding(.trailing, 28)
        .padding(.vertical, 14)
        .background(Palette.headerBar)
    }

    // MARK: - Cards

    private var cards: some View {
        VStack(spacing: 16) {
            noticeCard
            providerCard
            if displayedProvider.isExternal {
                SettingsKeyCard(
                    model: model, settings: settings, provider: displayedProvider,
                    keyDraft: $keyDraft, keySaveFailed: $keySaveFailed,
                    modelDraft: $modelDraft
                )
                // Resets the card's local probe flags when the displayed
                // provider changes; the bindings above are reset by the
                // pending/selection observers.
                .id(displayedProvider)
            }
            SettingsRetranslateCard(model: model, settings: settings)
            SettingsTargetLanguageCard(model: model, settings: settings)
            appearanceCard
            modelCard
            sessionCard
            HStack {
                Spacer()
                if let writeReviewURL = URL(string: Self.writeReviewURLString) {
                    Link("Rate Mimidasu on the App Store", destination: writeReviewURL)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .accessibilityHint("Opens the App Store review page for Mimidasu")
                        .help("Opens the App Store review page for Mimidasu")
                        // pointerStyle needs a hover-tracking view; the no-op
                        // onHover activates it (same as ToastStackView).
                        .onHover { _ in }
                        .pointerStyle(.link)
                        .padding(.vertical, 4)
                }
                Spacer()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private func row(label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.secondaryText)
            Spacer()
            value()
        }
    }

    // MARK: - Notice (privacy / external)

    @ViewBuilder
    private var noticeCard: some View {
        if displayedProvider.isExternal {
            notice(
                icon: "arrow.up.forward.circle.fill",
                title: "External provider",
                body: "Sentences will be sent to \(displayedProvider.displayName) for translation."
            )
        } else {
            notice(
                icon: "lock.shield.fill",
                title: "Private by default",
                body: "On-device translation keeps every sentence local."
            )
        }
    }

    private func notice(icon: String, title: String, body: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.primaryText)
                Text(body)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.secondaryText)
            }
            Spacer()
        }
        .padding(14)
        .cardSurface(fill: Palette.accent.opacity(0.08), stroke: Palette.accent.opacity(0.3))
    }

    // MARK: - Appearance

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel("APPEARANCE", color: Palette.label)
            ModePicker(
                help: "Window appearance — System follows the macOS setting",
                modes: Appearance.allCases,
                selection: $appearance.binding,
                label: \.label,
                icon: \.systemImage,
                track: Palette.segmentTrack,
                selectedFill: Palette.segmentFill,
                unselectedColor: Palette.mutedText
            )
        }
        .padding(16)
        .cardSurface(shadow: Palette.cardShadow)
    }

    // MARK: - Model / session diagnostics

    /// A card per ASR model choice (select / download), the models folder,
    /// and a re-check action.
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel("SPEECH MODEL", color: Palette.label)
            HStack(alignment: .top, spacing: 12) {
                ForEach(ASRModelChoice.allCases) { choice in
                    SettingsModelRow(choice: choice, model: model)
                }
            }
            HStack {
                Spacer()
                SettingsPill(label: "Re-check model") {
                    Task { await model.refreshModelAvailability() }
                }
                .padding(.top, 6)
            }
        }
        .padding(16)
        .cardSurface(shadow: Palette.cardShadow)
    }

    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel("SESSION", color: Palette.label)
            row(label: "Entries") {
                Text("\(model.entries.count)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.primaryText)
            }
            settingsDivider()
            row(label: "Engine") {
                Text(
                    model.engineIsMock
                        ? "Mock (runtime not installed)"
                        : "CrispASR · \(model.asrModelSettings.selected.displayName) (Metal)"
                )
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.engineText)
            }
            settingsDivider()
            row(label: "Translation") {
                // Truthful mid-fallback: the suffix shows only while the
                // latched Apple engine is actually the active one — a manual
                // retry that re-engaged the external engine hides it. The
                // base label reads the attached provider (never the picker),
                // so it can't describe an engine the queue isn't using.
                Text(
                    settings.activeEngineDescription(
                        fallbackActive:
                        model.translationFallbackActive &&
                            model.activeTranslationEngine == .apple,
                        attachedProvider: model.activeExternalProvider,
                        appleHighFidelity: model.appleHighFidelity
                    )
                )
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Palette.primaryText)
            }
        }
        .padding(16)
        .cardSurface(shadow: Palette.cardShadow)
    }
}

// MARK: - Provider card

private extension SettingsView {
    var providerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            KickerLabel("TRANSLATION · PROVIDER", color: Palette.label)
            // Fixed-height well: four full rows visible, the rest scroll.
            // Rows keep their own hover wash; nothing here clips it. The
            // selected provider can sit below the fold, so opening the card
            // scrolls its row into view instead of showing no checkmark.
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: ProviderListMetrics.rowSpacing) {
                        ForEach(TranslationProvider.allCases) { provider in
                            providerRow(provider)
                                .id(provider)
                        }
                    }
                }
                .frame(height: ProviderListMetrics.viewportHeight)
                .onAppear {
                    proxy.scrollTo(settings.selectedProvider)
                }
                .onChange(of: settings.selectedProvider) { _, provider in
                    proxy.scrollTo(provider)
                }
            }
        }
        .padding(16)
        .cardSurface(shadow: Palette.cardShadow)
    }

    /// Row-click policy: select immediately for Apple and the current
    /// provider, verify a configured external provider first, and open the
    /// key card for an unconfigured one.
    func handleProviderRowClick(_ provider: TranslationProvider) {
        // Re-clicking the row that is already connecting is a no-op: it
        // must not invalidate the probe it is waiting on.
        guard verifyingProvider != provider else { return }
        // Any other click captures its intent now, before the async probe
        // starts, so a later click supersedes it deterministically.
        let intent = model.noteTranslationProviderIntent()
        if provider == .apple || settings.selectedProvider == provider {
            cancelVerification()
            pendingProvider = nil
            settings.select(provider)
        } else if settings.hasKey(for: provider) {
            verifyThenSelect(provider, intent: intent)
        } else {
            cancelVerification()
            pendingProvider = provider
        }
    }

    func providerRow(_ provider: TranslationProvider) -> some View {
        let selected = settings.selectedProvider == provider
        return Button {
            handleProviderRowClick(provider)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: provider.settingsIcon)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Palette.accent : Palette.primaryText.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Palette.tileFill)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.settingsName(
                        deepLTier: settings.deepLTier,
                        appleHighFidelity: model.appleHighFidelity
                    ))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Text(provider.settingsDetail(hasKey: settings.hasKey(for: provider)))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.mutedText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                if verifyingProvider == provider {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Connecting…")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.mutedText)
                    }
                } else if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(height: ProviderListMetrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(
            RoundedRectangle(cornerRadius: 8, style: .continuous),
            tint: Palette.accent, opacity: 0.1
        )
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Drops any in-flight row verification: its completion can neither
    /// clear a newer spinner nor open a key card for a superseded intent.
    func cancelVerification() {
        verificationSerial &+= 1
        verifyingProvider = nil
    }

    /// Probe-then-select for a configured external provider row: the
    /// selection moves only if the live probe verifies the key (via
    /// `AppModel.verifyAndSelectTranslationProvider`); failure opens the key
    /// card, where the recorded failure and Remove/Test actions show.
    func verifyThenSelect(_ provider: TranslationProvider, intent: Int) {
        guard verifyingProvider != provider else { return }
        verificationSerial &+= 1
        let serial = verificationSerial
        verifyingProvider = provider
        Task {
            let outcome = await model.verifyAndSelectTranslationProvider(
                provider, intent: intent
            )
            guard serial == verificationSerial else { return }
            verifyingProvider = nil
            // A superseded probe is not a failure: the user already clicked
            // something else, so its key card must not open.
            if outcome == .failed {
                pendingProvider = provider
            }
        }
    }
}
