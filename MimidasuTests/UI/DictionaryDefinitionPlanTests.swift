@testable import Mimidasu
import Testing

/// The four definition hosts' argument tables: every rendering decision each
/// host hands the shared entry definition, pinned as one plan per mode, plus
/// each mode's entry-selection policy over real entry lists.
///
/// These are the values the hosts pass today — a change to any one of them
/// fails here rather than on screen.
@Suite("Dictionary definition plan")
struct DictionaryDefinitionPlanTests {

    // MARK: - Fixtures

    private func entry(_ seq: Int, keb: String? = nil, reb: String? = nil) -> JMDictEntry {
        JMDictEntry(
            entSeq: seq,
            keb: keb,
            reb: reb,
            common: false,
            jlpt: nil,
            hatsuon: nil,
            accPatts: nil,
            zoPatts: nil,
            senses: []
        )
    }

    private func hit(entSeq: Int, keb: String, reb: String) -> DictionarySearchHit {
        DictionarySearchHit(
            entSeq: entSeq,
            keb: keb,
            reb: reb,
            common: false,
            jlpt: nil,
            isName: false,
            namePosTokens: [],
            matchKind: .exact,
            matchedField: .keb,
            highlightRange: nil,
            glossPreview: []
        )
    }

    /// The three-entry homograph list the selection tests page through —
    /// 方 / 報 / 法 all read ほう, the row-shaped sibling set the search
    /// fallback and the clamps are written for.
    private func homographs() -> [JMDictEntry] {
        [
            entry(1, keb: "方", reb: "ほう"),
            entry(2, keb: "報", reb: "ほう"),
            entry(3, keb: "法", reb: "ほう")
        ]
    }

    // MARK: - The popover's table

    @Test("the popover pages directly: header-row pager, headword, badges, icon copy, bare star, every sense unwrapped")
    func popoverTable() {
        let plan = DictionaryDefinitionPlan(mode: .popover)

        #expect(plan.mode == .popover)
        #expect(plan.entrySelection == .directIndex)
        #expect(plan.showsEntryPager)
        #expect(plan.pagerPlacement == .contentHeader)
        #expect(plan.rendersEntryPager)
        #expect(plan.showsHeadword)
        #expect(plan.showsBadges)
        #expect(plan.favoriteStyle == .popover)
        #expect(plan.copyPlacement == .icon)
        #expect(plan.senseLimit == nil)
        #expect(plan.glossLimit == nil)
        #expect(!plan.wrapsSensePOS)
    }

    // MARK: - The sidebar card's table

    @Test("the sidebar card renders the pager on its own label row and wraps sense POS, with headword, badges, icon copy, tiled star")
    func sidebarCardTable() {
        let plan = DictionaryDefinitionPlan(mode: .sidebarCard)

        #expect(plan.mode == .sidebarCard)
        #expect(plan.entrySelection == .directIndex)
        #expect(!plan.showsEntryPager)
        #expect(plan.pagerPlacement == .hostLabelRow)
        #expect(plan.rendersEntryPager)
        #expect(plan.showsHeadword)
        #expect(plan.showsBadges)
        #expect(plan.favoriteStyle == .card)
        #expect(plan.copyPlacement == .icon)
        #expect(plan.senseLimit == nil)
        #expect(plan.glossLimit == nil)
        #expect(plan.wrapsSensePOS)
    }

    // MARK: - The favorites row's table

    @Test("the favorites row opens on the promoted lead: no headword, no pager, badges kept, no copy or star, all senses inline")
    func favoritesRowTable() {
        let plan = DictionaryDefinitionPlan(mode: .favoritesRow)

        #expect(plan.mode == .favoritesRow)
        #expect(plan.entrySelection == .promotedLead)
        #expect(!plan.showsEntryPager)
        #expect(plan.pagerPlacement == .none)
        #expect(!plan.rendersEntryPager)
        #expect(!plan.showsHeadword)
        #expect(plan.showsBadges)
        #expect(plan.favoriteStyle == .card)
        #expect(plan.copyPlacement == .none)
        #expect(plan.senseLimit == nil)
        #expect(plan.glossLimit == nil)
        #expect(!plan.wrapsSensePOS)
    }

    // MARK: - The search row's table

    @Test("the search row suppresses headword and badges, asks for a pager it never draws, no copy or star chrome")
    func searchRowTable() {
        let plan = DictionaryDefinitionPlan(mode: .searchRow)

        #expect(plan.mode == .searchRow)
        #expect(plan.entrySelection == .rowValidatedFallback)
        #expect(plan.showsEntryPager)
        #expect(plan.pagerPlacement == .contentHeader)
        #expect(!plan.rendersEntryPager)
        #expect(!plan.showsHeadword)
        #expect(!plan.showsBadges)
        #expect(plan.favoriteStyle == .card)
        #expect(plan.copyPlacement == .none)
        #expect(plan.senseLimit == nil)
        #expect(plan.glossLimit == nil)
        #expect(!plan.wrapsSensePOS)
    }

    // MARK: - Direct-index selection (popover, sidebar card)

    @Test(
        "a direct-index host pages into the lookup's own entries",
        arguments: [DictionaryDefinitionMode.popover, .sidebarCard]
    )
    func directIndexInBounds(mode: DictionaryDefinitionMode) {
        let plan = DictionaryDefinitionPlan(mode: mode)
        let entries = homographs()

        #expect(plan.displayEntryIndex(in: entries, requestedIndex: 0) == 0)
        #expect(plan.displayEntryIndex(in: entries, requestedIndex: 2) == 2)
    }

    @Test(
        "a direct-index host shows nothing when its requested index is stale",
        arguments: [DictionaryDefinitionMode.popover, .sidebarCard]
    )
    func directIndexOutOfBounds(mode: DictionaryDefinitionMode) {
        let plan = DictionaryDefinitionPlan(mode: mode)
        let entries = homographs()

        #expect(plan.displayEntryIndex(in: entries, requestedIndex: 3) == nil)
        #expect(plan.displayEntryIndex(in: entries, requestedIndex: -1) == nil)
        #expect(plan.displayEntryIndex(in: [], requestedIndex: 0) == nil)
    }

    // MARK: - Favorites-row selection

    @Test("the favorites row opens on the entry favorite-first promotion led")
    func favoritesOpenOnPromotedLead() {
        let result = LookupResult(matched: "ほう", entries: homographs())
        let identity = FavoriteIdentity(keys: Set(["報"].map(FavoriteIdentity.normalize)))

        let promoted = FavoritesPromotion.promotingFavorites(in: result, identity: identity)
        let plan = DictionaryDefinitionPlan(mode: .favoritesRow)

        #expect(promoted.entries.first?.keb == "報")
        #expect(plan.displayEntryIndex(in: promoted.entries) == 0)
    }

    @Test("a favorites row with nothing to show renders its own text instead")
    func favoritesEmptyLookup() {
        let plan = DictionaryDefinitionPlan(mode: .favoritesRow)

        #expect(plan.displayEntryIndex(in: []) == nil)
    }

    @Test("a favorites row always opens on the lead, never on a paged or row index")
    func favoritesIgnoreForeignIndices() {
        let plan = DictionaryDefinitionPlan(mode: .favoritesRow)
        let entries = homographs()

        #expect(plan.displayEntryIndex(in: entries, requestedIndex: 1, rowEntryIndex: 2) == 0)
    }

    // MARK: - Search-row selection: the row-index → validated-page chain

    @Test("an untouched search row opens on the entry it names even when the lookup ranks a sibling first")
    func searchRowOwnEntry() {
        let entries = homographs()
        let rowHit = hit(entSeq: 2, keb: "報", reb: "ほう")
        let rowEntryIndex = DictionarySearchState.rowEntryIndex(
            for: rowHit, in: LookupResult(matched: "ほう", entries: entries)
        )
        let plan = DictionaryDefinitionPlan(mode: .searchRow)

        #expect(rowEntryIndex == 1)
        #expect(plan.displayEntryIndex(in: entries, rowEntryIndex: rowEntryIndex) == 1)
    }

    @Test("a search row ignores the page only the tap hosts read")
    func searchRowIgnoresRequestedIndex() {
        let entries = homographs()
        let plan = DictionaryDefinitionPlan(mode: .searchRow)

        #expect(plan.displayEntryIndex(in: entries, requestedIndex: 2, rowEntryIndex: 1) == 1)
    }

    @Test("a stepped search row keeps its stored page while the lead it was stored against still leads")
    func searchRowKeepsStoredPage() {
        let entries = homographs()
        let plan = DictionaryDefinitionPlan(mode: .searchRow)

        #expect(plan.displayEntryIndex(
            in: entries, rowEntryIndex: 2, storedIndex: 1, storedLead: 1
        ) == 1)
    }

    @Test("a stored page from before a promotion reorders falls back to the row's own entry")
    func searchRowFallsBackOnLeadChange() {
        let entries = homographs()
        let plan = DictionaryDefinitionPlan(mode: .searchRow)

        #expect(plan.displayEntryIndex(
            in: entries, rowEntryIndex: 2, storedIndex: 0, storedLead: 3
        ) == 2)
        #expect(plan.displayEntryIndex(
            in: entries, rowEntryIndex: 2, storedIndex: 0, storedLead: nil
        ) == 2)
    }

    @Test("a lead-matched search row with no stored page starts at the promoted lead")
    func searchRowWithoutStoredPageStartsAtLead() {
        let entries = homographs()
        let plan = DictionaryDefinitionPlan(mode: .searchRow)

        #expect(plan.displayEntryIndex(
            in: entries, rowEntryIndex: 2, storedIndex: nil, storedLead: 1
        ) == 0)
    }

    @Test("a search row over a lookup with no entries renders the row's own text instead")
    func searchRowEmptyLookup() {
        let plan = DictionaryDefinitionPlan(mode: .searchRow)

        #expect(plan.displayEntryIndex(
            in: [], rowEntryIndex: 0, storedIndex: 0, storedLead: 1
        ) == nil)
    }

    @Test(
        "the search row clamps a stored page into the promoted list",
        arguments: zip(
            [-3, -2, -1, 0, 1, 2, 3, 4, 5],
            [0, 0, 0, 0, 1, 2, 2, 2, 2]
        )
    )
    func clampsStoredPage(storedIndex: Int, expected: Int) {
        let plan = DictionaryDefinitionPlan(mode: .searchRow)

        #expect(plan.displayEntryIndex(
            in: homographs(), rowEntryIndex: 2, storedIndex: storedIndex, storedLead: 1
        ) == expected)
    }

    @Test(
        "the search row clamps its row fallback into the promoted list",
        arguments: zip(
            [-3, -2, -1, 0, 1, 2, 3, 4, 5],
            [0, 0, 0, 0, 1, 2, 2, 2, 2]
        )
    )
    func clampsRowFallback(rowEntryIndex: Int, expected: Int) {
        let plan = DictionaryDefinitionPlan(mode: .searchRow)

        #expect(plan.displayEntryIndex(
            in: homographs(), rowEntryIndex: rowEntryIndex, storedIndex: 0, storedLead: 3
        ) == expected)
    }

    // MARK: - The pinned hosts' call-site wiring

    @Test("the pinned-host switch reads the presentation's page as the direct-index request")
    func pinnedSwitchReadsPresentationPage() {
        let presentation = LookupPresentation(
            content: .found(
                result: LookupResult(matched: "ほう", entries: homographs()),
                also: [],
                origin: .tappedSurface
            ),
            entryIndex: 2,
            anchor: .liveStrip
        )
        guard case let .found(result, _, _) = presentation.content else {
            Issue.record("the fixture presentation is found")
            return
        }
        // The shared pinned-content switch hands the presentation's page
        // straight to the plan — the same input both tap hosts read directly.
        for mode in [DictionaryDefinitionMode.popover, .sidebarCard] {
            let plan = DictionaryDefinitionPlan(mode: mode)

            #expect(plan.displayEntryIndex(
                in: result.entries, requestedIndex: presentation.entryIndex
            ) == 2)
        }
    }

    @Test("a stale pinned page leaves the plan with nothing: the popover's blank, the card's hint")
    func pinnedSwitchStalePageSelectsNothing() {
        let presentation = LookupPresentation(
            content: .found(
                result: LookupResult(matched: "ほう", entries: homographs()),
                also: [],
                origin: .tappedSurface
            ),
            entryIndex: 3,
            anchor: nil
        )
        guard case let .found(result, _, _) = presentation.content else {
            Issue.record("the fixture presentation is found")
            return
        }
        // nil is the switch's signal to fall back to the host's own empty
        // render — nothing in the popover, the hint in the card.
        for mode in [DictionaryDefinitionMode.popover, .sidebarCard] {
            let plan = DictionaryDefinitionPlan(mode: mode)

            #expect(plan.displayEntryIndex(
                in: result.entries, requestedIndex: presentation.entryIndex
            ) == nil)
        }
    }
}
