/// Read-only facade over the re-translate coordinator's plan. Views build the
/// plan through these methods; the coordinator stays a state-layer detail.
extension AppModel {
    /// The plan for a surface and target, using the persisted Settings
    /// re-translate selection.
    func retranslatePlan(surface: RetranslateSurface, target: TargetLanguage) -> RetranslatePlan {
        retranslate.plan(surface: surface, target: target)
    }

    /// The plan for a surface and target with an explicit picker selection.
    func retranslatePlan(
        surface: RetranslateSurface,
        target: TargetLanguage,
        selection: RetranslateEngine
    ) -> RetranslatePlan {
        retranslate.plan(surface: surface, target: target, selection: selection)
    }

    /// The row's retry affordance and provenance marker.
    func retranslateRowPlan(
        for entry: SessionEntry,
        surface: RetranslateSurface,
        target: TargetLanguage
    ) -> RetranslateRowPlan {
        retranslate.rowPlan(for: entry, surface: surface, target: target)
    }
}
