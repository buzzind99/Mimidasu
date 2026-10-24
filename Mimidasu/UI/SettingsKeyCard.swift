import SwiftUI

/// The API key card: per-provider key entry (straight to the Keychain on
/// save, never held beyond the field), an opaque dot mask for a saved key
/// with Remove/Test actions, and the model field for chat-model providers.
/// Shown for external providers — the selected one, or a pending (not yet
/// configured) one being set up. Saving a key auto-runs a connection test; a
/// successful test (auto or via the Test button) selects the provider,
/// subject to the cloud disclosure, and activates its engine once the
/// selection applies.
struct SettingsKeyCard: View {
    var model: AppModel
    @Bindable var settings: TranslationSettings
    let provider: TranslationProvider
    @Binding var keyDraft: String
    @Binding var keySaveFailed: Bool
    /// Edit buffer for the provider's model field. The stored model only
    /// changes after a successful probe, so an abandoned edit never reaches
    /// the engine.
    @Binding var modelDraft: String
    @State private var isTestingConnection = false
    @State private var isTestingModel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The card is only rendered for external providers, so the
            // kicker can only ever read an external provider's name.
            KickerLabel(provider.displayName.uppercased(), color: Palette.label)
            if settings.hasKey(for: provider) {
                savedKeyRows()
            } else {
                keyEntryRows()
            }
            if provider.isLLM {
                modelField
            }
        }
        .padding(16)
        .cardSurface(shadow: Palette.cardShadow)
    }

    // MARK: - Saved key

    @ViewBuilder
    private func savedKeyRows() -> some View {
        HStack(spacing: 8) {
            Text("••••••••••••••••")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .settingsFieldBackground()
            SettingsPill(label: "Remove") {
                settings.removeKey(for: provider)
                keyDraft = ""
            }
            // The model and key probes share the provider's probe sequence,
            // so the card runs one at a time.
            SettingsPill(label: "Test", isEnabled: !isTestingConnection && !isTestingModel) {
                runConnectionTest(for: provider)
            }
        }
        HStack(spacing: 6) {
            connectionStatus(provider)
            Spacer()
            Text("Key is stored securely in the Keychain.")
                .font(.system(size: 10))
                .foregroundStyle(Palette.mutedText)
        }
    }

    // MARK: - Key entry

    @ViewBuilder
    private func keyEntryRows() -> some View {
        HStack(spacing: 8) {
            SecureField("Paste API key", text: $keyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .settingsFieldBackground()
            SettingsPill(
                label: "Save", prominent: true,
                isEnabled: !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty
            ) {
                saveKeyDraft(for: provider)
            }
        }
        if keySaveFailed {
            Text("Couldn't save the key to the Keychain.")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.statusRed)
        } else {
            HStack(spacing: 6) {
                Spacer()
                Text("Key is stored securely in the Keychain.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.mutedText)
            }
        }
    }

    // MARK: - Model

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 7) {
            settingsDivider()
            KickerLabel("MODEL", color: Palette.label, size: 9.5)
            HStack(spacing: 8) {
                TextField(provider.defaultModel, text: $modelDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .settingsFieldBackground()
                    // The probe commits the draft it started with; editing
                    // mid-flight would leave the field and stored model
                    // describing different values.
                    .disabled(isTestingModel)
                if isTestingModel {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Testing…")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondaryText)
                        .fixedSize()
                }
                // Save probes the draft through the real request path before
                // committing it; a failed probe records its result and leaves
                // both the stored model and the attached engine untouched.
                // Disabled while the draft matches the stored model, while
                // its own probe is running, or while the other probe is
                // running.
                SettingsPill(
                    label: "Save", prominent: true,
                    isEnabled: settings.hasKey(for: provider)
                        && !isTestingModel
                        && !isTestingConnection
                        && trimmedModelDraft != settings.model(for: provider)
                ) {
                    saveModelDraft(for: provider)
                }
            }
            if !settings.hasKey(for: provider) {
                Text("Save an API key to test and store a model.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.mutedText)
            }
        }
    }

    private var trimmedModelDraft: String {
        modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveModelDraft(for provider: TranslationProvider) {
        guard !isTestingModel, !isTestingConnection, settings.hasKey(for: provider) else { return }
        let draft = trimmedModelDraft
        isTestingModel = true
        Task {
            let verified = await model.verifyModel(draft, for: provider)
            isTestingModel = false
            // A completion must describe the field the user still sees: the
            // key can disappear (or the window can reopen and reset the card)
            // while the probe is airborne.
            guard verified,
                  trimmedModelDraft == draft,
                  settings.hasKey(for: provider)
            else { return }
            let previousEffective = settings.effectiveModel(for: provider)
            settings.setModel(draft, for: provider)
            // Re-attach only when the saved provider is the attached one and
            // the effective model actually changed. Editing another provider's
            // card must not tear down the live engine or the retranslate lane.
            guard provider == settings.selectedProvider,
                  settings.effectiveModel(for: provider) != previousEffective
            else { return }
            model.translationProviderDidChange()
        }
    }

    // MARK: - Connection test

    @ViewBuilder
    private func connectionStatus(_ provider: TranslationProvider) -> some View {
        if isTestingConnection {
            ProgressView()
                .controlSize(.mini)
            Text("Testing…")
                .font(.system(size: 11))
                .foregroundStyle(Palette.secondaryText)
        } else {
            switch settings.testResult(for: provider) {
            case .success:
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text("Connected")
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.statusGreen)
            case let .failure(message):
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                    Text(message)
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.statusRed)
            case nil:
                EmptyView()
            }
        }
    }

    private func runConnectionTest(for provider: TranslationProvider) {
        guard !isTestingConnection, !isTestingModel else { return }
        // A test is a later provider action: an airborne row probe for an
        // older intent must not stage its selection afterwards.
        model.noteTranslationProviderIntent()
        isTestingConnection = true
        Task {
            // Probe + result recording + select-on-success live on `AppModel`,
            // shared with the provider row's verify-before-select flow.
            _ = await model.verifyAndSelectTranslationProvider(provider)
            isTestingConnection = false
        }
    }

    /// Writes the draft key to the secure store. The draft is cleared only
    /// after a successful save so a Keychain failure (auth denied, storage
    /// error) doesn't lose the paste; the failure surfaces as an inline
    /// caption until the next attempt or provider switch.
    private func saveKeyDraft(for provider: TranslationProvider) {
        let key = keyDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        do {
            try settings.saveKey(key, for: provider)
            keyDraft = ""
            keySaveFailed = false
            // Auto-check the connection on save; a verified key activates
            // the provider's engine right away (see `runConnectionTest`).
            runConnectionTest(for: provider)
        } catch {
            keySaveFailed = true
        }
    }
}
