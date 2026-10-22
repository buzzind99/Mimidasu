import SwiftUI

/// Chronological transcript, oldest first, newest appended at the bottom.
///
/// Scroll behavior is a thin manual pin. The `ScrollView`-only role-scoped
/// default anchors (`.initialOffset`, `.sizeChanges`) do not apply to `List`
/// — `defaultScrollAnchor` is documented as associating the anchor to a
/// `ScrollView` — so `List` relies entirely on the pin:
///
/// - Starting at the newest sentence is covered by `reAnchor` on appear and
///   on every entries change.
/// - Growth of the content under a stationary offset — a translation landing
///   on any row, a new entry, a viewport resize — re-anchors to the bottom
///   marker while pinned.
///
/// The manual pin is decided by scroll direction: only movement of the
/// offset *away* from the bottom (the user dragging up) can drop it, and
/// scrolling back down into the bottom re-engages it. That decision only
/// reads the distance on ticks where the content and viewport span held
/// still, so a translation landing in the same tick as a drag can't
/// masquerade as either. Distance measured from freshly grown content would
/// read the growth itself and drop the pin exactly when it must act, so
/// growth ticks never feed the pin decision.
/// Re-anchoring then chases the bottom marker on every geometry tick until
/// the content sits flush: a single scrollTo can land short while List's
/// estimated layout is still settling, so the chase converges quietly.
///
/// A finished archive record is the exception: it is a transcript of
/// something that already happened, so it opens at its oldest sentence and
/// the pin is released — nothing moves the viewport while the reader reads
/// it. The record's identity is what decides that: a record change (the
/// first record, a second record over the first, or the return to the live
/// feed) is made once, and the pin decision follows the mode the record
/// leaves behind.
struct TranscriptView: View {
    var model: AppModel
    /// Raises the main window's un-star question for a word popover. Forwarded
    /// straight from `ContentView`'s single slot: a popover is its own window,
    /// so the question cannot be raised from inside one.
    let onFavoriteRemovalRequest: (String) -> Void
    @AppStorage(ReadingAnnotation.storageKey) private var readingAnnotation = ReadingAnnotation.romaji
    @AppStorage(CursorMode.storageKey) private var cursorMode = CursorMode.none
    @AppStorage(UIScale.storageKey) private var uiScale = UIScale.default
    /// Scroll state held out of the body: per-tick geometry writes land on
    /// the model, never on this view's graph, so a drag doesn't re-diff
    /// the rows.
    @State private var scroll = PinnedScrollModel(
        topAnchorID: TranscriptView.topAnchorID,
        bottomAnchorID: TranscriptView.bottomAnchorID
    )

    static let bottomAnchorID = "transcript-bottom-anchor"
    static let topAnchorID = "transcript-top-anchor"

    var body: some View {
        // Read here, in the body, and not inside the row closure: the matcher
        // accessor only *builds* a closure and observes nothing. This read is
        // belt-and-braces — `RubyTextView`'s own body resolves membership and
        // so observes the store directly — but it keeps the transcript's
        // dependence on favorite state visible at the surface that hands the
        // matcher down, and it re-runs this body when membership changes.
        _ = model.favorites.revision
        return ScrollViewReader { proxy in
            List {
                Color.clear
                    .frame(height: 1)
                    .padding(.top, 16)
                    .id(Self.topAnchorID)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                if model.entries.isEmpty {
                    emptyState
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(model.entries) { entry in
                    TranscriptRow(
                        entry: entry,
                        displayLanguage: model.openArchive != nil
                            ? model.archiveViewingCode : nil,
                        annotation: readingAnnotation,
                        scale: uiScale,
                        cursorMode: cursorMode,
                        onCopy: { text in model.copySnippet(text) },
                        onLookup: { token in
                            model.handleLookupTap(
                                token,
                                source: .transcript(
                                    sentenceIndex: entry.sentence.index,
                                    tokenIndex: token.tokenIndex
                                )
                            )
                        },
                        lookupPopover: { tokenIndex in
                            lookupPopover(entry.sentence.index, tokenIndex)
                        },
                        isFavorite: model.favoriteSegmentMatcher,
                        onRetry: { sentence in model.retranslateSentence(sentence) },
                        retryEnabled: retryEnabled(for: entry),
                        isRetranslating: model.pendingRetranslations.contains(entry.sentence.index),
                        retranslateMarker: retranslateMarker(for: entry),
                        fadesIn: TranscriptScrollPin.rowFadesIn(
                            in: scrollMode, isNewest: entry.id == model.entries.last?.id
                        )
                    )
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
            // Circular jump buttons, stacked bottom-trailing (clears the
            // toast zone at the top-trailing corner where the toast stack
            // mounts).
            .overlay(alignment: .bottomTrailing) {
                ScrollJumpButtons(scroll: scroll, proxy: proxy)
                    .padding(.trailing, 24)
                    .padding(.bottom, 20)
            }
            // The bottom marker row is 1pt tall; without this List enforces
            // a minimum row height that would keep it from sitting flush.
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
                // Only the live feed follows its tail: a finished record
                // stays where the reader put it.
                guard TranscriptScrollPin.followsTail(in: scrollMode) else { return }
                scroll.reAnchor(proxy)
            }
            .onChange(of: model.openArchive?.id) { _, newID in
                // A record opens at its oldest sentence; the live feed
                // resumes following its tail. A second record is a change
                // too: the mode does not move, the content does.
                scroll.applyRecord(newID, proxy: proxy)
            }
            .onAppear {
                // List has no `.initialOffset` anchor (ScrollView-only);
                // start pinned at the newest sentence — unless a record is
                // already open, which starts at its oldest.
                scroll.applyRecord(model.openArchive?.id, proxy: proxy)
                guard TranscriptScrollPin.followsTail(in: scrollMode) else { return }
                scroll.reAnchor(proxy)
            }
            .onChange(of: readingAnnotation) { _, _ in
                // Mode toggles resize every row; re-anchor if pinned.
                scroll.reAnchor(proxy)
            }
            .onChange(of: uiScale) { _, _ in
                // Scaling resizes every row; re-anchor if pinned.
                scroll.reAnchor(proxy)
            }
            .onChange(of: cursorMode) { _, _ in
                // Dictionary mode restructures every row's flow children
                // (per-token units, no plain-run folding), changing row
                // heights; re-anchor if pinned.
                scroll.reAnchor(proxy)
            }
        }
    }

    /// The transcript the pane holds: the live feed, or a finished archive
    /// record. Read from the archive state rather than from the scroll
    /// model, so the mode and the content change that comes with it are
    /// decided from one source — the record is already open when its rows
    /// land, and a content change must not be read as a live append.
    private var scrollMode: TranscriptScrollPin.Mode {
        model.openArchive == nil ? .live : .archive
    }

    /// Whether this row's retry affordance may be shown. Every clause is a
    /// precondition `AppModel.retranslateSentence` enforces, so a shown button
    /// is one whose click would be served rather than silently refused:
    /// a live session, and this row not already retranslating. Read per row
    /// here, in the body, so the invalidation that changes any of them
    /// re-renders the rows.
    ///
    /// The worker and status clauses ride state the queue reports through
    /// (`model.translationWorkerActive`, `model.translationStatus`) because
    /// `TranslationQueue` is not `@Observable` and could not drive this view
    /// directly. Both are skipped while an alternate retry engine resolves:
    /// a dead session engine is exactly when routing the retry elsewhere is
    /// useful, and the lane's availability (`alternateRetranslateEngineActive`)
    /// already answers "will this click be served". The row's own sentence
    /// being queued or airborne is deliberately *not* consulted: that state
    /// cannot reach this view either, and a queued line's button is the
    /// common case anyway — it simply comes back with the batch.
    private func retryEnabled(for entry: SessionEntry) -> Bool {
        // Archive mode: the opened session is the deliverer (the lane routes
        // through its dedicated engines), so the button is held back by an
        // in-flight retry, a claimed bulk job (one translation at a time),
        // and a retry selection that resolves to no engine (a key-less
        // external pick would only report unavailable).
        if model.openArchive != nil {
            return !model.pendingRetranslations.contains(entry.sentence.index)
                && !model.archiveTranslationRunning
                && model.alternateRetranslateEngineActive
        }
        guard SessionPhaseMachine.isLive(model.phase) else { return false }
        if !model.alternateRetranslateEngineActive {
            guard model.translationWorkerActive else { return false }
            if case .unavailable = model.translationStatus {
                return false
            }
        }
        return !model.pendingRetranslations.contains(entry.sentence.index)
    }

    /// Marker text for a retried row: only when the lane produced it, the
    /// lane's engine differs from the current active engine, and the toggle
    /// is on. The Apple branch's identity is provisional until the
    /// activation's probe lands — every activation, Apple or external,
    /// resets the tuple to `(false, nil)` and it lands async — so comparing
    /// against a not-yet-landed identity would flash a marker on a
    /// just-retried row that the landing probe immediately removes. External
    /// identity needs no probe.
    private func retranslateMarker(for entry: SessionEntry) -> String? {
        guard model.translationSettings.showsRetranslateMarker else { return nil }
        // The row's target language: the open archive's viewed language in
        // archive mode (retries stamp it), the settings target live.
        let targetCode = model.openArchive != nil
            ? (model.archiveViewingCode ?? model.translationSettings.targetLanguage.code)
            : model.translationSettings.targetLanguage.code
        // Matched by language, not `.last`: the row renders every
        // translation, so the marker must describe the one shown for the
        // current target rather than whichever came last.
        guard let translation = entry.translations.first(where: { existing in
            existing.lang == targetCode
        }),
            let engine = translation.engine
        else { return nil }
        // Once the probe has landed not-installed for the row's target, a
        // row stamped `.appleHighFidelity` actually holds the fast model's
        // text — the framework silently falls back — so its marker must not
        // claim Apple Intelligence. The probe is evidence only for the pair
        // it ran for, so the comparison is scoped to the row's target.
        if engine == .appleHighFidelity, model.highFidelityKnownUnavailable(for: targetCode) {
            return nil
        }
        // Archive mode: there is no live engine to differ from — every
        // archive retry runs through a dedicated alternate, so the stamp
        // itself is the provenance. The probe-pending hold below describes
        // the live session's identity and does not apply.
        if model.openArchive != nil {
            return "· via \(engine.markerName)"
        }
        // Only the Apple kinds depend on the probe. While it is pending the
        // identity is unknown under ANY live engine (external sessions probe
        // too, and a probe killed by a stop leaves the tuple at
        // `(false, nil)` while the transcript stays on screen), so an Apple
        // marker waits for it.
        if engine == .appleFast || engine == .appleHighFidelity,
           model.appleHighFidelityProbe.targetCode == nil
        {
            return nil
        }
        guard engine != model.activeEngineKind else { return nil }
        return "· via \(engine.markerName)"
    }

    /// Per-word popover presentation for the row's word units: the
    /// binding is true only while this exact word is the selection's
    /// anchor (a different-word retap dismisses and re-presents), and the
    /// content is the shared entry view once the async lookup has landed.
    ///
    /// Handed to each row as a closure that `RubyTextView`'s body invokes at
    /// layout time, so the `model.selectedLookup` reads below register the
    /// observation on the node that has to repaint — the word units — rather
    /// than on this body, which never calls it.
    private func lookupPopover(
        _ sentenceIndex: Int, _ tokenIndex: Int
    ) -> RubyTextView.LookupPopover {
        let source = SelectedLookup.Source.transcript(
            sentenceIndex: sentenceIndex, tokenIndex: tokenIndex
        )
        return RubyTextView.LookupPopover(
            isPresented: model.lookupPopoverBinding(for: source),
            content: model.selectedLookup?.popoverItem(for: source).map { item in
                DictionaryPopoverView(
                    model: model,
                    selected: item,
                    onFavoriteRemovalRequest: onFavoriteRemovalRequest
                )
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No transcript yet")
                .font(ScaledFont.title3(uiScale.factor))
                .foregroundStyle(Theme.secondaryText)
            Text("Play any Japanese audio on your Mac (e.g. a livestream in your browser) and press Start session.")
                .font(ScaledFont.callout(uiScale.factor))
                .foregroundStyle(Theme.secondaryText.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

/// Pure tick→decision core for the transcript's manual bottom pin,
/// separated from the observable scroll state so the pin semantics stay
/// unit-testable without a scroll view. The rules:
///
/// - Only movement of the offset *away* from the bottom (the user dragging
///   up) can drop the pin, and only on ticks where the content and viewport
///   span held still, so a translation landing in the same tick as a drag
///   can't masquerade as either. Distance measured from freshly grown
///   content would read the growth itself and drop the pin exactly when it
///   must act, so growth ticks never feed the pin decision.
/// - While pinned, movement toward the bottom chases the bottom marker
///   until the content sits flush: a single scrollTo can land short while
///   List's estimated layout is still settling.
/// - Unpinned, movement into the bottom tolerance re-engages the pin.
enum TranscriptScrollPin {
    /// Distance from the viewport bottom within which the user counts as
    /// "at the bottom": dragging up past this unpins, scrolling down into
    /// it re-pins. Small by design — the re-anchor chase lands flush, so
    /// no slack is needed to absorb imprecise landings.
    static let pinTolerance: CGFloat = 8
    /// Distance under which a re-anchored landing counts as flush and the
    /// chase stops; also the span delta under which a tick counts as
    /// "still" for the pin decision.
    static let settleEpsilon: CGFloat = 2

    /// The scroll values that separate offset movement (the pin is
    /// re-evaluated) from stationary content or viewport growth (the pin
    /// re-anchors).
    struct Snapshot: Equatable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat
        var insetTop: CGFloat
        var insetBottom: CGFloat

        var distanceToBottom: CGFloat {
            contentHeight + insetBottom - (offsetY + containerHeight)
        }

        /// Distance from the viewport top to the content top; zero when
        /// scrolled flush to the oldest sentence.
        var distanceToTop: CGFloat {
            offsetY + insetTop
        }

        /// Everything that changes `distanceToBottom` except the offset:
        /// content height, content insets, viewport size. A tick where the
        /// span moved is growth or relayout, and its distance is not a
        /// trustworthy pin signal.
        var span: CGFloat {
            contentHeight + insetBottom - containerHeight
        }
    }

    /// What one geometry tick asks the scroll owner to do: whether to
    /// re-anchor to the bottom marker, and what the pin flag becomes.
    struct Tick: Equatable {
        var reanchors: Bool
        var pinnedAfter: Bool
    }

    /// Which transcript the pane holds: the live session's growing feed, or
    /// a finished archive record.
    enum Mode: Equatable {
        /// The live feed: the newest sentence sits at the bottom and the
        /// view follows it.
        case live
        /// A finished record: it opens at its oldest sentence, and the
        /// viewport stays where the reader leaves it.
        case archive
    }

    /// What a mode flip asks the scroll owner to do: whether the viewport
    /// jumps to the content top, and what the pin flag becomes.
    struct ModeChange: Equatable {
        var jumpsToTop: Bool
        var pinnedAfter: Bool
    }

    /// Maps a mode flip onto the scroll owner's two decisions. The live feed
    /// keeps following its tail; a finished record opens at its oldest
    /// sentence with the pin released, so nothing moves the viewport
    /// afterwards.
    static func modeChange(to mode: Mode) -> ModeChange {
        switch mode {
        case .live:
            ModeChange(jumpsToTop: false, pinnedAfter: true)
        case .archive:
            ModeChange(jumpsToTop: true, pinnedAfter: false)
        }
    }

    /// Whether a content change (a new entry, a landed translation) pulls
    /// the viewport to the bottom. The live feed follows its tail; a
    /// finished record is left where the reader put it.
    static func followsTail(in mode: Mode) -> Bool {
        mode == .live
    }

    /// Whether a row fades in on appearance. Only the live feed's newest row
    /// does: a finished record's rows already exist when the pane takes them,
    /// and a shorter record can promote a recycled row that never faded.
    static func rowFadesIn(in mode: Mode, isNewest: Bool) -> Bool {
        mode == .live && isNewest
    }

    /// Whether the down button re-engages the bottom pin. The live feed
    /// re-pins and chases its tail; a finished record has no tail to follow,
    /// so its down button is a one-shot jump to the newest sentence.
    static func downButtonRepins(in mode: Mode) -> Bool {
        mode == .live
    }

    /// What one geometry tick says about a record's pending top jump.
    enum TopJump: Equatable {
        /// The viewport sits flush with the content top: the jump landed.
        case settled
        /// The reader scrolled away from the top: their place wins over
        /// the pending jump.
        case cancelled
        /// The jump is still owed: its landing came up short, or the
        /// content grew under a reader who has not moved.
        case retry
        /// Nothing to do.
        case none
    }

    /// Maps one geometry tick onto the pending top jump's fate.
    ///
    /// The reader's own scroll outranks the jump: once the jump has run,
    /// their move is theirs and the pending retry is dropped — so a later
    /// content growth cannot pull them back to the top. A movement before
    /// the jump runs is ambiguous (it can still carry the outgoing
    /// transcript's geometry), so the caller keeps the jump owed for that
    /// tick.
    ///
    /// The one movement that is not the reader's is the content swap's
    /// own clamping: a shorter record pulls the offset up, and a swap is
    /// not a scroll. A shrinking content is what tells the two apart —
    /// growing content never pulls the offset up.
    ///
    /// Once the jump has fired, the next tick is its landing: flush with
    /// the content top settles it, short of it leaves the retry owed. An
    /// upward move in that same tick cannot be told apart from the
    /// landing, so the retry wins once.
    static func topJump(old: Snapshot, new: Snapshot, jumpInFlight: Bool) -> TopJump {
        if new.distanceToTop <= settleEpsilon {
            return .settled
        }
        let contentMoved = abs(new.contentHeight - old.contentHeight) > settleEpsilon
        let contentShrank = new.contentHeight < old.contentHeight - settleEpsilon
        let offsetDelta = new.offsetY - old.offsetY
        if offsetDelta > settleEpsilon {
            // The reader scrolled down: nothing else moves the offset that
            // way, and their place wins over the jump.
            return .cancelled
        }
        if jumpInFlight {
            // The jump's own landing, short of the top: the retry is owed.
            return .retry
        }
        if offsetDelta < -settleEpsilon, !contentShrank {
            // The reader scrolled up with the content holding its size (or
            // growing): their place wins over the jump.
            return .cancelled
        }
        if contentMoved {
            return .retry
        }
        return .none
    }

    /// Maps one geometry tick onto the pin rules; `pinned` is the flag
    /// before the tick.
    ///
    /// A finished record is the exception: it never follows its tail, so
    /// its pin stays released and nothing re-anchors its viewport — not
    /// when the reader scrolls, and not when the content grows under them.
    static func tick(old: Snapshot, new: Snapshot, pinned: Bool, mode: Mode) -> Tick {
        guard mode == .live else {
            return Tick(reanchors: false, pinnedAfter: false)
        }
        if new.offsetY > old.offsetY {
            // The offset moved toward the bottom: our own re-anchor
            // landing (which can come up short of flush), or the user
            // paging down.
            if pinned {
                // Chase the marker until the content sits flush.
                return Tick(
                    reanchors: new.distanceToBottom > settleEpsilon, pinnedAfter: pinned
                )
            }
            // The user scrolled down to the bottom: re-engage.
            if new.distanceToBottom <= pinTolerance {
                return Tick(reanchors: true, pinnedAfter: true)
            }
            return Tick(reanchors: false, pinnedAfter: pinned)
        }
        if new.offsetY < old.offsetY {
            // The offset moved away from the bottom: the user dragged up
            // (or an overscroll bounce settled back). Content growth never
            // moves the offset, but it inflates the distance, so only
            // trust that distance on ticks where the span held still. On a
            // mixed tick (a translation landing mid-drag, a bounce
            // settling under lazy relayout) the decision is deferred: the
            // chase re-anchors a bounce, and the next still tick
            // re-evaluates from the accumulated distance.
            guard abs(new.span - old.span) <= settleEpsilon else {
                return Tick(reanchors: false, pinnedAfter: pinned)
            }
            return Tick(
                reanchors: false,
                pinnedAfter: new.distanceToBottom <= pinTolerance
            )
        }
        // The offset didn't move but the content or viewport changed size
        // (row grew, entry appended, window or live row resized): keep the
        // bottom edge in view without dropping the pin. Distance here is
        // the growth itself, so it must never feed the pin decision.
        return Tick(reanchors: pinned, pinnedAfter: pinned)
    }

    /// Jump-button visibility off the same signals the pin consumes: the
    /// down button tracks the pin flag, the up button the distance from
    /// the content top. Before the first tick lands (`nil` snapshot) both
    /// hide.
    ///
    /// A finished record is the exception: its down button is a one-shot
    /// jump to the newest sentence rather than a re-pin, so it is offered
    /// only while there is something below the viewport.
    static func visibility(
        pinned: Bool, snapshot: Snapshot?, mode: Mode
    ) -> (up: Bool, down: Bool) {
        let up = snapshot.map { snap in snap.distanceToTop > pinTolerance } ?? false
        switch mode {
        case .live:
            return (up: up, down: !pinned)
        case .archive:
            let hasBelow = snapshot.map { snap in snap.distanceToBottom > pinTolerance } ?? false
            return (up: up, down: hasBelow)
        }
    }
}

/// Scroll-side state for a manual bottom-pinned scroll view (the
/// transcript list and the translation overlay), held out of the owning
/// view so per-tick geometry writes never invalidate the row-diffing
/// body: the raw snapshot, pin flag, and coalescing flag are written
/// every tick but read only inside these handlers — no body observes
/// them — while the jump buttons observe just the two visibility flags,
/// which are assigned only on an actual flip.
@Observable
@MainActor
final class PinnedScrollModel {
    private var snapshot: TranscriptScrollPin.Snapshot?
    private var pinnedToBottom = true
    /// Coalesces bursts of re-anchor requests into a single scrollTo.
    private var reAnchorScheduled = false
    /// The open record's id; nil for the live feed. The transcript the
    /// pane holds follows from it, so the two can never disagree.
    private var recordID: Int64?
    /// The record's opening jump: pending until the viewport sits flush
    /// with the content top.
    private var topJumpPending = false
    /// The jump's scroll has been issued and its landing has not been seen
    /// yet: the next tick tells whether it landed flush or short.
    private var topJumpInFlight = false
    /// How many jumps the pending record has been given.
    private var topJumpsIssued = 0
    /// Coalesces bursts of top-jump requests into a single scrollTo.
    private var topJumpScheduled = false
    /// Identifies the transcript a queued jump belongs to: a block from an
    /// older record must not scroll the current one.
    private var topJumpGeneration = 0

    private(set) var showUpButton = false
    private(set) var showDownButton = false

    private let topAnchorID: String
    private let bottomAnchorID: String

    init(topAnchorID: String, bottomAnchorID: String) {
        self.topAnchorID = topAnchorID
        self.bottomAnchorID = bottomAnchorID
    }

    /// The transcript the pane holds: the live feed, or the open record. A
    /// record is a finished transcript; the live feed is a growing one.
    private var mode: TranscriptScrollPin.Mode {
        recordID == nil ? .live : .archive
    }

    /// Applies a record change: the live feed follows its tail, a finished
    /// record opens at its oldest sentence with the pin released, so no
    /// content change moves the viewport afterwards.
    ///
    /// A second record is a change too: the mode does not move, but the
    /// content does, so the new record still opens at its oldest sentence.
    ///
    /// The jump to the top is scheduled rather than immediate: the
    /// record's rows are not laid out when the record opens, and the
    /// scroll range is not final until they are.
    func applyRecord(_ recordID: Int64?, proxy: ScrollViewProxy) {
        guard recordID != self.recordID else { return }
        self.recordID = recordID
        let change = TranscriptScrollPin.modeChange(to: mode)
        pinnedToBottom = change.pinnedAfter
        topJumpPending = change.jumpsToTop
        topJumpInFlight = false
        topJumpsIssued = 0
        // A jump queued for the previous transcript belongs to it: abandon
        // it so its block cannot serve (or spend the budget of) this one.
        topJumpGeneration &+= 1
        topJumpScheduled = false
        // The previous transcript's geometry says nothing about this one's
        // buttons; hide them until the new layout ticks.
        snapshot = nil
        refreshVisibility()
        if change.jumpsToTop {
            issueTopJump(proxy)
        }
    }

    /// Consumes one geometry tick: re-evaluates the pin decision, refreshes
    /// jump-button visibility, and chases the bottom marker as decided. A
    /// tick that flips nothing and re-anchors nowhere touches no observed
    /// property, so it renders nothing.
    func handle(
        old: TranscriptScrollPin.Snapshot,
        new: TranscriptScrollPin.Snapshot,
        proxy: ScrollViewProxy
    ) {
        snapshot = new
        settleTopJump(old: old, new: new, proxy: proxy)
        let tick = TranscriptScrollPin.tick(
            old: old, new: new, pinned: pinnedToBottom, mode: mode
        )
        pinnedToBottom = tick.pinnedAfter
        refreshVisibility()
        if tick.reanchors {
            reAnchor(proxy)
        }
    }

    /// Up button: release the pin and jump to the oldest sentence (no
    /// chase: the pin is off, so nothing re-fires until the user scrolls
    /// back down). The reader has taken over the position, so a pending
    /// record jump is dropped.
    func unpinAndScrollToTop(_ proxy: ScrollViewProxy) {
        pinnedToBottom = false
        topJumpPending = false
        topJumpInFlight = false
        refreshVisibility()
        scrollToTop(proxy)
    }

    /// Down button: re-engage the pin and chase the bottom marker. A
    /// finished record has no tail to follow, so its down button is a
    /// one-shot jump to the newest sentence: the pin stays released and
    /// nothing chases the marker afterwards.
    func repinAndChase(_ proxy: ScrollViewProxy) {
        // The reader has taken over the position: a pending opening or
        // retry jump must not undo their move.
        topJumpPending = false
        topJumpInFlight = false
        guard TranscriptScrollPin.downButtonRepins(in: mode) else {
            scrollToBottom(proxy)
            return
        }
        pinnedToBottom = true
        refreshVisibility()
        reAnchor(proxy)
    }

    /// Scrolls to the bottom marker on the next runloop tick, once the
    /// layout that triggered the call has landed. Coalesces bursts of
    /// geometry ticks into a single scrollTo; if the landing ends up short
    /// of flush, the chase continues from the geometry handler. The pin is
    /// re-checked at execution time so a user drag that slipped in between
    /// still wins.
    func reAnchor(_ proxy: ScrollViewProxy) {
        guard !reAnchorScheduled else { return }
        reAnchorScheduled = true
        DispatchQueue.main.async { @MainActor [self] in
            reAnchorScheduled = false
            guard pinnedToBottom else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(topAnchorID, anchor: .top)
        }
    }

    /// Scrolls to the bottom marker once, without a chase: a finished
    /// record's one-shot jump to its newest sentence.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    /// The record's opening jump: settled when the viewport sits flush with
    /// the content top. A jump that landed short of the top — the record's
    /// rows were not laid out when it was issued — is given a second chance
    /// once the content height moves.
    ///
    /// It is never chased: once the jump has run, a reader who scrolls away
    /// keeps their place and the pending retry is dropped with it. While the
    /// jump is still queued, a movement cannot be attributed to the reader,
    /// so it does not cancel the jump.
    private func settleTopJump(
        old: TranscriptScrollPin.Snapshot,
        new: TranscriptScrollPin.Snapshot,
        proxy: ScrollViewProxy
    ) {
        guard topJumpPending else { return }
        let decision = TranscriptScrollPin.topJump(
            old: old, new: new, jumpInFlight: topJumpInFlight
        )
        switch decision {
        case .settled:
            topJumpPending = false
            topJumpInFlight = false
        case .cancelled where topJumpScheduled:
            // The opening jump has not run yet, so this movement can still
            // carry the outgoing transcript's geometry. Keep the jump owed;
            // the next tick, after the jump has run, decides for the new
            // content.
            break
        case .cancelled:
            topJumpPending = false
            topJumpInFlight = false
        case .retry:
            // The landing has been seen: the next tick is the reader's.
            topJumpInFlight = false
            guard topJumpsIssued < Self.maxTopJumps else {
                // The budget is spent: the record keeps the offset it
                // landed on, and the pending jump is dropped rather than
                // left armed for the rest of the record's life.
                topJumpPending = false
                return
            }
            issueTopJump(proxy)
        case .none:
            break
        }
    }

    /// Issues the jump to the content top, at most a couple of times per
    /// record: the first lands on the rows once they are there, the second
    /// covers the jump that came too early. Past that the jump is dropped.
    private func issueTopJump(_ proxy: ScrollViewProxy) {
        guard topJumpsIssued < Self.maxTopJumps, !topJumpScheduled else { return }
        topJumpsIssued += 1
        topJumpScheduled = true
        let generation = topJumpGeneration
        DispatchQueue.main.async { @MainActor [self] in
            // A record change abandoned this jump: it must not clear the
            // new record's scheduled flag or scroll its pane.
            guard generation == topJumpGeneration else { return }
            topJumpScheduled = false
            guard topJumpPending else { return }
            // The jump is ours: the next tick is its landing, not the
            // reader's move.
            topJumpInFlight = true
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(topAnchorID, anchor: .top)
            }
        }
    }

    /// The jumps one record may be given: the opening jump, and the retry
    /// that covers a jump issued before the rows were laid out.
    private static let maxTopJumps = 2

    private func refreshVisibility() {
        let next = TranscriptScrollPin.visibility(
            pinned: pinnedToBottom, snapshot: snapshot, mode: mode
        )
        if showUpButton != next.up {
            showUpButton = next.up
        }
        if showDownButton != next.down {
            showDownButton = next.down
        }
    }
}

/// A pinned scroll view's jump buttons — the only per-scroll-tick UI.
/// Observes just the scroll model's two visibility flags, so the vast
/// majority of geometry ticks (plain drags, the re-anchor chase, pin
/// churn) render nothing at all. Bare column: placement/padding belongs
/// to the composing view.
struct ScrollJumpButtons: View {
    let scroll: PinnedScrollModel
    let proxy: ScrollViewProxy
    var glyphColor: Color = Theme.annotationPink

    var body: some View {
        VStack(spacing: 10) {
            jumpButton("chevron.up", visible: scroll.showUpButton) {
                scroll.unpinAndScrollToTop(proxy)
            }
            jumpButton("chevron.down", visible: scroll.showDownButton) {
                scroll.repinAndChase(proxy)
            }
        }
    }

    private func jumpButton(
        _ systemImage: String,
        visible: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(glyphColor)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(Theme.jumpButtonBackground)
                        .overlay(Circle().stroke(Theme.jumpButtonStroke))
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.18), value: visible)
        .pointerStyle(visible ? .link : nil)
    }
}
