import Foundation

/// The single author of Filter changes: every exclusion, carry-over, and floor
/// rule lives in `apply`, so "what clears what" has exactly one answer and the
/// panel and the search state are thin dispatchers. The other half of the
/// contract is `normalized` — the one canonical impossibility (Common under
/// Names).
extension DictionarySearchFilters {
    /// Every way the Filter set may change. The panel dispatches these; the
    /// search state funnels every write through `apply`, so a raw impossible
    /// value cannot be parked in the window's state.
    enum FilterEvent: Equatable, Sendable {
        case setScope(Scope)
        case toggleJLPTLevel(Int)
        case toggleNameType(String)
        case togglePOS(POSGroup)
        case toggleMatchGroup(MatchGroup)
        case clearJLPTLevels
        case clearNameTypes
        case clearPOS
        case selectAllMatchGroups
        case toggleCommonOnly
        case reset
    }

    /// The single author of Filter changes: pure, non-throwing, total. Every
    /// returned value has `normalized` applied, so the Common-under-Names
    /// impossibility cannot leak through any event.
    ///
    /// The rules, event by event:
    ///
    /// - Scope: leaving `.all`, or moving between `.words` and `.names`,
    ///   clears nothing — the kept selection restores on return. Entering
    ///   `.all` resolves the carry-over: from `.words` the name types clear
    ///   (JLPT/POS stay); from `.names` JLPT and POS clear (name types win);
    ///   from `.all` nothing clears.
    /// - JLPT/POS toggles: selecting one under `.all` clears `nameTypes` —
    ///   their conjunction can only answer zero rows. Coexisting word-side
    ///   filters stay. Removing a selection clears nothing.
    /// - Name-type toggles: selecting one under `.all` clears `jlptLevels`
    ///   and `posGroups` — both word-side; removing one clears nothing.
    /// - Match groups: the last active group cannot be switched off — this
    ///   function cannot empty a non-empty set (a raw empty set passed in is
    ///   preserved, not repaired).
    /// - Common: toggling under `.names` from the reachable state (flag
    ///   already cleared) is a net no-op — normalization clears the flag the
    ///   toggle just set, so a disabled chip can never keep a silent
    ///   zero-answer filter alive.
    /// - Reset: back to the defaults, whatever the state.
    func apply(_ event: FilterEvent) -> DictionarySearchFilters {
        var next = self
        switch event {
        case .clearJLPTLevels:
            next.jlptLevels = []
        case .clearNameTypes:
            next.nameTypes = []
        case .clearPOS:
            next.posGroups = []
        case .selectAllMatchGroups:
            next.matchGroups = Set(MatchGroup.allCases)
        case .toggleCommonOnly:
            next.commonOnly.toggle()
        case .reset:
            next = DictionarySearchFilters()
        case .setScope, .toggleJLPTLevel, .toggleNameType, .togglePOS, .toggleMatchGroup:
            next.applySelection(event)
        }
        return next.normalized
    }

    /// The selection events, each routed to its mutating helper. Split from
    /// `apply` so both dispatches stay inside the size budget; `apply` routes
    /// exactly these events here, and a new case is forced by the compiler
    /// into both halves.
    private mutating func applySelection(_ event: FilterEvent) {
        switch event {
        case let .setScope(newScope):
            setScope(newScope)
        case let .toggleJLPTLevel(level):
            toggleJLPTLevel(level)
        case let .toggleNameType(badge):
            toggleNameType(badge)
        case let .togglePOS(group):
            togglePOS(group)
        case let .toggleMatchGroup(group):
            toggleMatchGroup(group)
        case .clearJLPTLevels, .clearNameTypes, .clearPOS, .selectAllMatchGroups, .toggleCommonOnly, .reset:
            // Applied by `apply(_:)` — this split is dispatch size, not a
            // second entry point.
            break
        }
    }

    /// The canonical impossibility (Common under Names) applied; idempotent.
    /// Names are never marked common in the source data, so `commonOnly`
    /// under `.names` can only answer zero rows — and the chip that shows it
    /// is greyed out there, so the user could not undo it from the chrome.
    /// Canonicalizing every value here makes raw readers (the chip's
    /// selection, the engine) truthful without a derived property.
    var normalized: DictionarySearchFilters {
        guard !scope.answersCommon, commonOnly else { return self }
        var next = self
        next.commonOnly = false
        return next
    }

    /// Toggles one JLPT level. Selecting under `.all` clears `nameTypes` —
    /// JLPT and name types are mutually exclusive there since their
    /// conjunction can only answer zero rows. POS coexists with JLPT (both
    /// word-side) and stays untouched. Under `.words`/`.names` the other
    /// row's selection is merely kept-but-ignored, and stays untouched.
    private mutating func toggleJLPTLevel(_ level: Int) {
        if jlptLevels.contains(level) {
            jlptLevels.remove(level)
        } else {
            jlptLevels.insert(level)
            if scope == .all {
                nameTypes = []
            }
        }
    }

    /// Toggles one name-type badge. Selecting under `.all` clears
    /// `jlptLevels` and `posGroups` — both word-side, both mutually exclusive
    /// with name types there. Under `.words`/`.names` the other selections
    /// stay untouched.
    private mutating func toggleNameType(_ badge: String) {
        if nameTypes.contains(badge) {
            nameTypes.remove(badge)
        } else {
            nameTypes.insert(badge)
            if scope == .all {
                jlptLevels = []
                posGroups = []
            }
        }
    }

    /// Toggles one POS group. Selecting under `.all` clears `nameTypes` —
    /// POS and name types are mutually exclusive there. JLPT coexists with
    /// POS (both word-side) and stays untouched. Under `.words`/`.names`
    /// the other selection stays untouched.
    private mutating func togglePOS(_ group: POSGroup) {
        if posGroups.contains(group) {
            posGroups.remove(group)
        } else {
            posGroups.insert(group)
            if scope == .all {
                nameTypes = []
            }
        }
    }

    /// Toggles one match tier. Removing the last active group is a no-op: an
    /// empty selection skips every stage and can only answer zero rows, and
    /// the chip that would show it is a positive control — so the floor
    /// lives here, once, rather than in each caller. The guard stops only
    /// *emptying* a non-empty set; a raw empty set stays empty, not repaired
    /// (raw construction remains legal for the engine and fixtures).
    private mutating func toggleMatchGroup(_ group: MatchGroup) {
        if matchGroups.contains(group) {
            guard matchGroups.count > 1 else { return }
            matchGroups.remove(group)
        } else {
            matchGroups.insert(group)
        }
    }

    /// Moves to a new scope, clearing the side that was kept-but-ignored
    /// when entering `.all`: from `.words` the name types clear (POS/JLPT
    /// stay); from `.names` JLPT and POS clear (name types win); from `.all`
    /// nothing clears. Leaving `.all` or moving between `.words` and
    /// `.names` clears nothing — the kept selection restores on return, and
    /// a single-scope predicate cannot form the empty conjunction.
    private mutating func setScope(_ newScope: Scope) {
        let leaving = scope
        scope = newScope
        if newScope == .all {
            switch leaving {
            case .words:
                nameTypes = []
            case .names:
                jlptLevels = []
                posGroups = []
            case .all:
                break
            }
        }
    }
}

extension DictionarySearchFilters.Scope {
    /// Whether entries in this scope can carry the filter's attribute, so the
    /// row is live and its selection effective. `.all` answers everything,
    /// and this table is the one source the model's derived predicates, the
    /// panel's row disables, and normalization all read.
    var answersJLPT: Bool {
        self != .names
    }

    var answersNameTypes: Bool {
        self != .words
    }

    var answersPOS: Bool {
        self != .names
    }

    var answersCommon: Bool {
        self != .names
    }
}
