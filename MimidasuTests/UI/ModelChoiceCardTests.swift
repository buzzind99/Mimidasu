import Foundation
@testable import Mimidasu
import Testing

/// Tests the shared model-choice card: what each flag does to the card's
/// chrome (the badge, the disabled state, the hover wash, the download
/// overlay and the footer), and the two surfaces' own flag tables — the
/// Settings row and the onboarding row differ in exactly those flags.
@MainActor
@Suite("ModelChoiceCard")
struct ModelChoiceCardTests {

    private let temporary: TemporaryDirectory

    init() throws {
        temporary = try TemporaryDirectory(prefix: "mimidasu-model-card")
    }

    // MARK: - Helpers

    /// A downloader over a scratch destination: the tests drive its state
    /// through the delegate entry points, so no transfer ever runs.
    private func makeDownloader() -> ModelDownloader {
        ModelDownloader(
            choice: .lite,
            destination: temporary.fileURL("model.gguf"),
            verdictStore: ModelVerifier.VerdictStore(url: temporary.fileURL("verdicts.json")),
            makeSession: { _ in URLSession(configuration: .ephemeral) },
            makeTask: { _ in nil }
        )
    }

    private func makeDownloadTask() throws -> URLSessionDownloadTask {
        let url = try #require(URL(string: "https://example.invalid/mimidasu-test.gguf"))
        return URLSession.shared.downloadTask(with: url)
    }

    private func makeCard(
        choice: ASRModelChoice = .lite,
        resolvedURL: URL? = nil,
        downloader: ModelDownloader? = nil,
        isSelected: Bool = false,
        selectionDisabled: Bool = false,
        showsSelectionBadge: Bool = true,
        showsDownloadControls: Bool = true,
        statusOnlyWhenSelected: Bool = false,
        footerStyle: ModelChoiceCard.FooterStyle = .sizeAndStatus
    ) -> ModelChoiceCard {
        ModelChoiceCard(
            choice: choice,
            resolvedURL: resolvedURL,
            downloader: downloader ?? makeDownloader(),
            isSelected: isSelected,
            selectionDisabled: selectionDisabled,
            onSelect: {},
            showsSelectionBadge: showsSelectionBadge,
            showsDownloadControls: showsDownloadControls,
            statusOnlyWhenSelected: statusOnlyWhenSelected,
            footerStyle: footerStyle
        )
    }

    private func makeSUT() async -> AppModel {
        let model = AppModel(
            translationSettings: isolatedTranslationSettings(suite: "test.ModelChoiceCard"),
            asrModelSettings: isolatedASRModelSettings(suite: "test.ModelChoiceCard"),
            favorites: isolatedFavorites(),
            archive: isolatedArchive(),
            highFidelityProbe: { _ in false },
            initialModelResolve: { _ in nil }
        )
        await model.initialModelCheck?.value
        return model
    }

    // MARK: - Badge

    @Test("the badge marks the selected card only")
    func badgeMarksTheSelectedCardOnly() {
        #expect(makeCard(isSelected: false).chrome.showsSelectionBadge == false)
        #expect(makeCard(isSelected: true).chrome.showsSelectionBadge == true)
        #expect(
            makeCard(isSelected: true, showsSelectionBadge: false).chrome.showsSelectionBadge == false,
            "a surface that shows no badge never badges the selected card"
        )
    }

    // MARK: - Disabled / hover

    @Test("a disabled card is inert and shows no hover")
    func disabledCardIsInert() {
        let card = makeCard(selectionDisabled: true)

        #expect(card.chrome.isDisabled)
        #expect(card.chrome.showsHover == false)
    }

    @Test("an enabled card hovers until it is selected")
    func enabledCardHoversUntilSelected() {
        #expect(makeCard(isSelected: false).chrome.showsHover)
        #expect(makeCard(isSelected: true).chrome.showsHover == false)
    }

    // MARK: - Download overlay

    @Test("the download overlay renders as the surface asks")
    func overlayFollowsTheSurface() {
        #expect(makeCard(showsDownloadControls: true).chrome.showsDownloadOverlay)
        #expect(makeCard(showsDownloadControls: false).chrome.showsDownloadOverlay == false)
    }

    // MARK: - Footer

    @Test("the Settings resting footer reads the size and the downloaded state")
    func settingsRestingFooter() {
        let url = URL(fileURLWithPath: "/tmp/lite.gguf")
        let size = ASRModelChoice.lite.approximateSize

        #expect(
            makeCard(resolvedURL: nil, footerStyle: .sizeAndStatus).chrome.footer
                == .sizeAndStatus(size: size, downloaded: false)
        )
        #expect(
            makeCard(resolvedURL: url, footerStyle: .sizeAndStatus).chrome.footer
                == .sizeAndStatus(size: size, downloaded: true)
        )
    }

    @Test("the onboarding resting footer is the size alone")
    func onboardingRestingFooter() {
        #expect(
            makeCard(resolvedURL: nil, footerStyle: .sizeOnly).chrome.footer
                == .sizeOnly(size: "~250 MB")
        )
    }

    @Test("a download in flight replaces the footer's resting line")
    func downloadReplacesTheRestingLine() async throws {
        let downloader = makeDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 250, totalBytesWritten: 250, totalBytesExpectedToWrite: 1000
        )
        #expect(await pollUntil {
            downloader.state == .downloading(progress: 0.25, bytes: 250, total: 1000)
        })

        let card = makeCard(downloader: downloader, footerStyle: .sizeAndStatus)

        #expect(card.chrome.footer == .progress(bytes: 250, total: 1000))
    }

    @Test("a failed download replaces the footer's resting line with the error")
    func failureReplacesTheRestingLine() async throws {
        let downloader = makeDownloader()
        let task = try makeDownloadTask()
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "offline"]
        )

        downloader.urlSession(.shared, task: task, didCompleteWithError: error)
        #expect(await pollUntil {
            downloader.state == .failed(ModelDownloader.downloadFailureMessage(error))
        })

        let card = makeCard(downloader: downloader, footerStyle: .sizeAndStatus)

        guard case let .error(message) = card.chrome.footer else {
            Issue.record("a failed download must replace the resting line with the error")
            return
        }
        #expect(
            message.hasPrefix("Download failed: offline."),
            "the card surfaces the downloader's own failure copy"
        )
    }

    @Test("the download status reaches the footer on the selected card only")
    func downloadStatusIsGatedOnTheSelection() async throws {
        let downloader = makeDownloader()
        let task = try makeDownloadTask()

        downloader.urlSession(
            .shared, downloadTask: task,
            didWriteData: 250, totalBytesWritten: 250, totalBytesExpectedToWrite: 1000
        )
        #expect(await pollUntil {
            downloader.state == .downloading(progress: 0.25, bytes: 250, total: 1000)
        })

        let unpicked = makeCard(
            downloader: downloader, isSelected: false,
            statusOnlyWhenSelected: true, footerStyle: .sizeOnly
        )
        let picked = makeCard(
            downloader: downloader, isSelected: true,
            statusOnlyWhenSelected: true, footerStyle: .sizeOnly
        )

        #expect(unpicked.chrome.footer == .sizeOnly(size: ASRModelChoice.lite.approximateSize))
        #expect(picked.chrome.footer == .progress(bytes: 250, total: 1000))
    }

    @Test("a stale completed download falls back to the resting line")
    func staleDoneFallsBackToTheRestingLine() {
        // The file was deleted after the download completed: the footer must
        // read the resolved URL, not the downloader's stale "done".
        let footer = ModelChoiceCard.footerPlan(
            state: .done(URL(fileURLWithPath: "/tmp/lite.gguf")),
            showsDownloadStatus: true,
            footerStyle: .sizeAndStatus,
            size: ASRModelChoice.lite.approximateSize,
            downloaded: false
        )

        #expect(
            footer == .sizeAndStatus(size: ASRModelChoice.lite.approximateSize, downloaded: false),
            "a deleted model must not read as downloaded"
        )
    }

    // MARK: - Surface flag tables

    @Test("the Settings card badges the model in use and always shows the download overlay")
    func settingsFlagTable() async {
        let model = await makeSUT()
        let row = SettingsModelRow(choice: .lite, model: model)
        let card = row.makeCard()

        #expect(card.chrome.showsSelectionBadge, "the model in use is badged")
        #expect(card.chrome.showsDownloadOverlay, "the Settings card always offers the download")
        #expect(card.chrome.usesAccentSurface, "the model in use wears the accent surface")
        #expect(
            card.chrome.footer == .sizeAndStatus(
                size: ASRModelChoice.lite.approximateSize, downloaded: false
            ),
            "the Settings footer reads the size and the downloaded state"
        )
    }

    @Test("the onboarding card shows no badge and gates the download status on the picked card")
    func onboardingFlagTable() async {
        let model = await makeSUT()
        let row = OnboardingModelRow(choice: .lite, model: model, downloader: makeDownloader())
        let card = row.makeCard()

        #expect(card.chrome.showsSelectionBadge == false, "the onboarding card never badges")
        #expect(
            card.chrome.footer == .sizeOnly(size: ASRModelChoice.lite.approximateSize),
            "the onboarding footer is the size alone"
        )
    }

    // MARK: - The selection action

    @Test("the selection action runs only on a card that may be selected")
    func selectionActionIsGuarded() {
        var selections = 0
        let card = ModelChoiceCard(
            choice: .lite,
            resolvedURL: nil,
            downloader: makeDownloader(),
            isSelected: false,
            selectionDisabled: false,
            onSelect: { selections += 1 },
            showsSelectionBadge: true,
            showsDownloadControls: true,
            statusOnlyWhenSelected: false,
            footerStyle: .sizeAndStatus
        )

        card.select()
        #expect(selections == 1, "an enabled, unselected card selects")

        card.select()
        #expect(selections == 2, "the card stays selectable until it is selected")
    }

    @Test("a disabled card and the model in use never fire the selection action")
    func blockedCardsDoNotSelect() {
        var selections = 0
        let card = ModelChoiceCard(
            choice: .lite,
            resolvedURL: nil,
            downloader: makeDownloader(),
            isSelected: true,
            selectionDisabled: false,
            onSelect: { selections += 1 },
            showsSelectionBadge: true,
            showsDownloadControls: true,
            statusOnlyWhenSelected: false,
            footerStyle: .sizeAndStatus
        )

        card.select()

        #expect(card.chrome.actionIsBlocked, "the model in use does not re-select")
        #expect(selections == 0, "the model in use never re-resolves and re-warms")
    }

    // MARK: - Surface state

    @Test("the Settings card marks the model in use")
    func settingsMarksTheModelInUse() async {
        let model = await makeSUT()
        let row = SettingsModelRow(choice: .lite, model: model)

        #expect(row.isInUse, "Lite is the default selection")

        model.asrModelSettings.select(.full)

        #expect(row.isInUse == false)
    }

    @Test("the Settings selection is disabled while the model is missing or the session runs")
    func settingsSelectionDisabled() async {
        let model = await makeSUT()
        let row = SettingsModelRow(choice: .lite, model: model)

        #expect(row.selectionDisabled, "a model that is not downloaded cannot be selected")

        await model.refreshModelAvailability(resolve: { _ in URL(fileURLWithPath: "/tmp/lite.gguf") })
        #expect(row.selectionDisabled == false, "a downloaded model can be selected")

        for phase in [SessionPhase.running, .paused, .starting] {
            model.phase = phase

            #expect(row.selectionDisabled, "a selection change waits for the next session start")
        }
    }

    @Test("the onboarding card's download overlay follows the picked card")
    func onboardingOverlayFollowsThePick() async {
        let model = await makeSUT()
        let row = OnboardingModelRow(choice: .lite, model: model, downloader: makeDownloader())

        #expect(row.isPicked, "Lite is the default selection")
        #expect(row.showsDownloadControls)

        model.asrModelSettings.select(.full)

        #expect(row.isPicked == false)
        #expect(row.showsDownloadControls == false)
    }
}
