import Foundation

/// Which surface a re-translate decision is rendered for. The live surface
/// feeds the transcript and the Settings card; the archive surface feeds the
/// opened archive's transcript and its engine picker. The two surfaces share
/// one rule set but not one outcome: an archive retry always runs a dedicated
/// engine, while a live `.session` retry runs the queue's attached engine.
enum RetranslateSurface: Equatable, Sendable {
    case live
    case archive
}

/// The high-fidelity evidence for one target pair: whether the pair offers
/// high fidelity, and whether a landed probe marks it known-unavailable.
struct RetranslateTierFacts: Equatable, Sendable {
    let highFidelityOffered: Bool
    let highFidelityKnownUnavailable: Bool
}

/// The live session's identity and queue attachment at the time the plan is
/// built. `workerAttached` reads the observable runtime mirror kept in sync
/// by the queue's workerChanged callback, falling back to the queue itself
/// when there is no live session.
struct RetranslateLiveFacts: Equatable, Sendable {
    let activeEngineKind: TranslationEngineKind
    let runsFast: Bool
    let runsHighFidelity: Bool
    let attachedProvider: TranslationProvider?
    let workerAttached: Bool
    let status: TranslationStatus
    let phaseIsLive: Bool
}

/// The two key predicates kept distinct on purpose: a stored key makes a route
/// executable, while a verified key makes a provider offerable in Settings.
struct RetranslateKeyFacts: Equatable, Sendable {
    let keyed: Set<TranslationProvider>
    let configured: Set<TranslationProvider>
}

/// The row-scoped facts: which sentences are already retranslating, whether a
/// bulk archive run holds the engine, whether provenance markers are shown,
/// and the target the last Apple probe landed for.
struct RetranslateRowFacts: Equatable, Sendable {
    let pendingIndexes: Set<Int>
    let archiveJobRunning: Bool
    let showsMarker: Bool
    let probeTargetCode: String?
}

/// One immutable snapshot of every fact a re-translate decision depends on.
/// The plan stores this snapshot and computes all decisions from it, so a view
/// body that reads a decision also observes the underlying settings, tier
/// evidence, and coordinator state.
struct RetranslateContext: Equatable, Sendable {
    let surface: RetranslateSurface
    let target: TargetLanguage
    let selection: RetranslateEngine
    let effectiveSelection: RetranslateEngine
    let tier: RetranslateTierFacts
    let live: RetranslateLiveFacts
    let keys: RetranslateKeyFacts
    let row: RetranslateRowFacts
}

/// Where a retry click goes. `.session` hands the sentence to the live queue;
/// `.lane` runs a dedicated engine; `.unavailable` refuses the click without
/// touching any state.
enum RetranslateRoute: Equatable, Sendable {
    case session
    case lane(RetranslateEngine)
    case unavailable(String)

    /// The lane's engine when the route runs one; nil for the session and
    /// unavailable routes.
    var laneEngine: RetranslateEngine? {
        guard case let .lane(engine) = self else { return nil }
        return engine
    }
}

/// One engine row in a picker: its selection identity plus whether the row can
/// be clicked and whether the provider behind it is configured.
struct RetranslateOption: Equatable, Sendable, Identifiable {
    let engine: RetranslateEngine
    let isSelectable: Bool
    let isConfigured: Bool

    var id: String {
        engine.rawValue
    }
}

/// What a transcript row renders for its retry affordance: whether the button
/// is live, whether the sentence is already in flight, and the provenance
/// suffix for its current translation.
struct RetranslateRowPlan: Equatable, Sendable {
    let isEnabled: Bool
    let isRetranslating: Bool
    let marker: String?
}

/// The single re-translate decision for one surface, target, and selection.
/// Every member is derived from `context`; there is no second stored truth.
struct RetranslatePlan: Equatable, Sendable {
    let context: RetranslateContext

    /// The click route, always resolved from the tier-degraded selection.
    var route: RetranslateRoute {
        switch (context.surface, context.effectiveSelection) {
        case (.live, .session):
            return .session
        case (.live, .appleFast):
            return context.live.runsFast ? .session : .lane(.appleFast)
        case (.live, .appleHighFidelity):
            return context.live.runsHighFidelity ? .session : .lane(.appleHighFidelity)
        case let (.live, selection):
            guard let provider = selection.provider else { return .session }
            if provider == context.live.attachedProvider {
                return .session
            }
            guard context.keys.keyed.contains(provider) else {
                return .unavailable("No API key stored for \(provider.displayName).")
            }
            return .lane(selection)
        case (.archive, .session), (.archive, .appleFast):
            return .lane(.appleFast)
        case (.archive, .appleHighFidelity):
            return .lane(.appleHighFidelity)
        case let (.archive, selection):
            guard let provider = selection.provider else { return .lane(.appleFast) }
            guard context.keys.keyed.contains(provider) else {
                return .unavailable("No API key stored for \(provider.displayName).")
            }
            return .lane(selection)
        }
    }

    /// True exactly when the click runs a dedicated engine rather than the
    /// live queue. The row gate uses the route itself, not this flag.
    var isAlternate: Bool {
        if case .lane = route {
            return true
        }
        return false
    }

    /// The engine rows a picker lists for this surface.
    var options: [RetranslateOption] {
        switch context.surface {
        case .live:
            liveOptions
        case .archive:
            archiveOptions
        }
    }

    /// The engine a Settings card or archive picker describes as selected.
    var displayedEngine: RetranslateEngine {
        switch context.surface {
        case .live:
            if options.contains(where: { option in option.engine == context.selection }) {
                return context.selection
            }
            if options.contains(where: { option in option.engine == context.effectiveSelection }) {
                return context.effectiveSelection
            }
            return .session
        case .archive:
            if options.contains(where: { option in option.engine == context.selection }) {
                return context.selection
            }
            return defaultEngine
        }
    }

    /// The engine a surface starts on when nothing is explicitly selected.
    var defaultEngine: RetranslateEngine {
        switch context.surface {
        case .live:
            .session
        case .archive:
            context.tier.highFidelityOffered ? .appleHighFidelity : .appleFast
        }
    }

    /// The row's retry affordance and provenance marker.
    func row(for entry: SessionEntry) -> RetranslateRowPlan {
        let isRetranslating = context.row.pendingIndexes.contains(entry.sentence.index)
        return RetranslateRowPlan(
            isEnabled: isRetranslating ? false : rowIsEnabled,
            isRetranslating: isRetranslating,
            marker: marker(for: entry)
        )
    }

    // MARK: - Options

    private var liveOptions: [RetranslateOption] {
        var options = [onDeviceOption(.session)]
        if !context.live.runsFast {
            options.append(onDeviceOption(.appleFast))
        }
        if context.tier.highFidelityOffered, !context.live.runsHighFidelity {
            options.append(onDeviceOption(.appleHighFidelity))
        }
        for provider in TranslationProvider.allCases where provider.isExternal {
            guard context.keys.configured.contains(provider),
                  provider != context.live.attachedProvider,
                  let engine = RetranslateEngine(provider: provider)
            else { continue }
            options.append(RetranslateOption(engine: engine, isSelectable: true, isConfigured: true))
        }
        return options
    }

    private var archiveOptions: [RetranslateOption] {
        var options: [RetranslateOption] = []
        if context.tier.highFidelityOffered {
            options.append(onDeviceOption(.appleHighFidelity))
        }
        options.append(onDeviceOption(.appleFast))
        for provider in TranslationProvider.allCases where provider.isExternal {
            guard let engine = RetranslateEngine(provider: provider) else { continue }
            let isConfigured = context.keys.configured.contains(provider)
            options.append(
                RetranslateOption(
                    engine: engine,
                    isSelectable: isConfigured,
                    isConfigured: isConfigured
                )
            )
        }
        return options
    }

    private func onDeviceOption(_ engine: RetranslateEngine) -> RetranslateOption {
        RetranslateOption(engine: engine, isSelectable: true, isConfigured: true)
    }

    // MARK: - Row

    private var rowIsEnabled: Bool {
        switch context.surface {
        case .live:
            guard context.live.phaseIsLive else { return false }
            switch route {
            case .lane:
                return true
            case .session:
                guard context.live.workerAttached else { return false }
                if case .unavailable = context.live.status {
                    return false
                }
                return true
            case .unavailable:
                return false
            }
        case .archive:
            guard !context.row.archiveJobRunning else { return false }
            switch route {
            case .lane:
                return true
            case .session, .unavailable:
                return false
            }
        }
    }

    private func marker(for entry: SessionEntry) -> String? {
        guard context.row.showsMarker else { return nil }
        guard let translation = entry.translation(for: context.target.code),
              let engine = translation.engine
        else { return nil }
        if engine == .appleHighFidelity, context.tier.highFidelityKnownUnavailable {
            return nil
        }
        if context.surface == .archive {
            return "· via \(engine.markerName)"
        }
        if engine == .appleFast || engine == .appleHighFidelity,
           context.row.probeTargetCode == nil
        {
            return nil
        }
        guard engine != context.live.activeEngineKind else { return nil }
        return "· via \(engine.markerName)"
    }
}
