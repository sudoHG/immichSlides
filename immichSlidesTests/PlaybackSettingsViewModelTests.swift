import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.sharedPlaybackRuntimeIsolation)
struct PlaybackSettingsViewModelTests {
    @Test
    func `external saves apply settings synchronously in notification order`() {
        let defaults = UserDefaults(suiteName: "PlaybackSettingsViewModelTests.synchronousExternalSaves")!
        let store = PlaybackSettingsStore(key: "playbackSettings.synchronousExternalSaves", defaults: defaults)
        store.clear()
        defer { store.clear() }
        let viewModel = PlaybackSettingsViewModel(store: store)
        var firstSettings = viewModel.settings
        firstSettings.autoPlayEnabled = false
        firstSettings.intervalSeconds = 12
        var secondSettings = firstSettings
        secondSettings.intervalSeconds = 20

        store.save(firstSettings)
        #expect(viewModel.settings == firstSettings)
        store.save(secondSettings)
        #expect(viewModel.settings == secondSettings)
        #expect(store.load() == secondSettings)
    }

    @Test
    func `a save posted from a background thread is applied on the main actor before the post returns`() async {
        let suiteName = "PlaybackSettingsViewModelTests.backgroundExternalSave"
        let key = "playbackSettings.backgroundExternalSave"
        let defaults = UserDefaults(suiteName: suiteName)!
        let viewModelStore = PlaybackSettingsStore(key: key, defaults: defaults)
        viewModelStore.clear()
        defer { viewModelStore.clear() }

        let viewModel = PlaybackSettingsViewModel(store: viewModelStore)
        var updatedSettings = viewModel.settings
        updatedSettings.autoPlayEnabled = false
        updatedSettings.intervalSeconds = 12

        let settingsToSave = updatedSettings
        // The background save builds its own store so nothing non-Sendable crosses threads.
        let saveOperation = BlockOperation {
            PlaybackSettingsStore(key: key, defaults: UserDefaults(suiteName: suiteName)!).save(settingsToSave)
        }
        let backgroundQueue = OperationQueue()
        backgroundQueue.addOperation(saveOperation)

        let didPostReturnBeforeDeadline = await waitUntil(pollInterval: .milliseconds(5)) {
            saveOperation.isFinished
        }

        #expect(didPostReturnBeforeDeadline)
        #expect(viewModel.settings == updatedSettings)
        #expect(viewModelStore.load() == updatedSettings)
    }

    @Test
    func `clearing filter A then selecting B keeps filtered mode`() {
        let (store, viewModel) = makeSettingsViewModelForFilterModeTransition(
            .filtered,
            suiteName: "PlaybackSettingsViewModelTests.clearThenSelectB"
        )
        defer { store.clear() }

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: true, isFilterEditorPresented: true)
        #expect(viewModel.settings.defaultPlaybackMode == .filtered)
        #expect(store.load()?.defaultPlaybackMode == .filtered)

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: false, isFilterEditorPresented: true)
        #expect(viewModel.settings.defaultPlaybackMode == .filtered)
        #expect(store.load()?.defaultPlaybackMode == .filtered)

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: false, isFilterEditorPresented: false)
        #expect(viewModel.settings.defaultPlaybackMode == .filtered)
        #expect(store.load()?.defaultPlaybackMode == .filtered)
    }

    @Test
    func `selecting B before removing filter A keeps filtered mode`() {
        let (store, viewModel) = makeSettingsViewModelForFilterModeTransition(
            .filtered,
            suiteName: "PlaybackSettingsViewModelTests.selectBThenRemoveA"
        )
        defer { store.clear() }

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: false, isFilterEditorPresented: true)
        #expect(viewModel.settings.defaultPlaybackMode == .filtered)
        #expect(store.load()?.defaultPlaybackMode == .filtered)

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: false, isFilterEditorPresented: true)
        #expect(viewModel.settings.defaultPlaybackMode == .filtered)
        #expect(store.load()?.defaultPlaybackMode == .filtered)

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: false, isFilterEditorPresented: false)
        #expect(viewModel.settings.defaultPlaybackMode == .filtered)
        #expect(store.load()?.defaultPlaybackMode == .filtered)
    }

    @Test
    func `clearing every filter returns to random mode only after the editor is dismissed`() {
        let (store, viewModel) = makeSettingsViewModelForFilterModeTransition(
            .filtered,
            suiteName: "PlaybackSettingsViewModelTests.clearAllFilters"
        )
        defer { store.clear() }

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: true, isFilterEditorPresented: true)
        #expect(viewModel.settings.defaultPlaybackMode == .filtered)
        #expect(store.load()?.defaultPlaybackMode == .filtered)

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: true, isFilterEditorPresented: false)
        #expect(viewModel.settings.defaultPlaybackMode == .random)
        #expect(store.load()?.defaultPlaybackMode == .random)
    }

    @Test
    func `random mode is unaffected by the filter selection becoming empty or not`() {
        let (store, viewModel) = makeSettingsViewModelForFilterModeTransition(
            .random,
            suiteName: "PlaybackSettingsViewModelTests.randomModeSelectionTransition"
        )
        defer { store.clear() }

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: true, isFilterEditorPresented: true)
        #expect(viewModel.settings.defaultPlaybackMode == .random)
        #expect(store.load()?.defaultPlaybackMode == .random)

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: false, isFilterEditorPresented: true)
        #expect(viewModel.settings.defaultPlaybackMode == .random)
        #expect(store.load()?.defaultPlaybackMode == .random)

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: false, isFilterEditorPresented: false)
        #expect(viewModel.settings.defaultPlaybackMode == .random)
        #expect(store.load()?.defaultPlaybackMode == .random)

        viewModel.enforcePlaybackModeInvariant(isFilterSelectionEmpty: true, isFilterEditorPresented: false)
        #expect(viewModel.settings.defaultPlaybackMode == .random)
        #expect(store.load()?.defaultPlaybackMode == .random)
    }

    @Test
    func `release XCTest build still defaults to observing playback settings`() {
        #expect(
            SlideShowViewModel.shouldObserveSettingsChangesByDefault(
                isDebugBuild: false,
                isRunningXCTest: true
            )
        )
        #expect(
            !SlideShowViewModel.shouldObserveSettingsChangesByDefault(
                isDebugBuild: true,
                isRunningXCTest: true
            )
        )
        #expect(
            SlideShowViewModel.shouldObserveSettingsChangesByDefault(
                isDebugBuild: true,
                isRunningXCTest: false
            )
        )
    }

    @Test
    func `persisted settings also enforce the five second minimum interval`() {
        let store = PlaybackSettingsStore()
        store.clear()
        defer { store.clear() }

        let viewModel = PlaybackSettingsViewModel(store: store)
        viewModel.settings.intervalSeconds = 3

        #expect(store.load()?.intervalSeconds == 5)
    }

    @Test
    func `control bar pause writes back immediately to the shared playback settings source`() {
        let testDefaults = UserDefaults(suiteName: "PlaybackSettingsViewModelTests.controlBarPause")!
        let store = PlaybackSettingsStore(
            key: "playbackSettings.controlBarPause",
            defaults: testDefaults
        )
        store.clear()
        defer { store.clear() }

        let settingsViewModel = PlaybackSettingsViewModel(store: store)
        let slideShowViewModel = SlideShowViewModel(
            settingsStore: store,
            observeSettingsChanges: true
        )

        #expect(settingsViewModel.settings.autoPlayEnabled)
        #expect(slideShowViewModel.isAutoPlay)

        slideShowViewModel.toggleAutoPlayFromUserInteraction()

        #expect(!slideShowViewModel.isAutoPlay)
        #expect(store.load()?.autoPlayEnabled == false)
        #expect(!settingsViewModel.settings.autoPlayEnabled)
    }

    @Test
    func `autoplay disabled before launch injects userPaused before the first scene is created`() {
        let testDefaults = UserDefaults(suiteName: "PlaybackSettingsViewModelTests.initiallyDisabledAutoplay")!
        let store = PlaybackSettingsStore(
            key: "playbackSettings.initiallyDisabledAutoplay",
            defaults: testDefaults
        )
        store.clear()
        defer { store.clear() }

        var settings = PlaybackSettings()
        settings.autoPlayEnabled = false
        store.save(settings)

        let slideShowViewModel = SlideShowViewModel(
            settingsStore: store,
            observeSettingsChanges: false
        )
        slideShowViewModel.replacePlaybackAssetsForTesting([
            Asset(
                id: "initially-paused-asset",
                type: "IMAGE",
                isFavorite: false,
                isTrashed: false,
                isArchived: false,
                exifInfo: nil,
                people: nil,
                tags: nil,
                livePhotoVideoID: nil,
                width: 1800,
                height: 1200
            )
        ])

        #expect(slideShowViewModel.sceneRenderSnapshot.suspensionReasons == [.userPaused])
    }

    @Test
    func `new Store, settings view model, and player instances reread the same saved playback settings`() {
        // "Restart" here only means rereading through new instances; killing the process via UI is not covered.
        let suiteName = "PlaybackSettingsViewModelTests.newInstancesReread"
        let key = "playbackSettings.newInstancesReread"
        let testDefaults = UserDefaults(suiteName: suiteName)!

        do {
            let writerStore = PlaybackSettingsStore(key: key, defaults: testDefaults)
            writerStore.clear()
            let writer = PlaybackSettingsViewModel(store: writerStore)
            writer.settings.autoPlayEnabled = false
            writer.settings.intervalSeconds = 12
            writer.settings.showExif = false
            writer.settings.displayMode = .singlePhoto
        }

        let restoredStore = PlaybackSettingsStore(key: key, defaults: testDefaults)
        defer { restoredStore.clear() }
        let restoredSettings = PlaybackSettingsViewModel(store: restoredStore)
        let restoredSlideShow = SlideShowViewModel(
            settingsStore: restoredStore,
            observeSettingsChanges: false
        )
        let loaded = restoredStore.load()

        #expect(loaded?.autoPlayEnabled == false)
        #expect(loaded?.intervalSeconds == 12)
        #expect(loaded?.showExif == false)
        #expect(loaded?.displayMode == .singlePhoto)
        #expect(restoredSettings.settings.autoPlayEnabled == false)
        #expect(restoredSettings.settings.intervalSeconds == 12)
        #expect(restoredSettings.settings.showExif == false)
        #expect(restoredSettings.settings.displayMode == .singlePhoto)
        #expect(restoredSlideShow.isAutoPlay == false)
        #expect(restoredSlideShow.autoPlayInterval == 12)
        if !PlatformCompat.forceSinglePhotoPlaybackForDebug {
            #expect(restoredSlideShow.isSmartFillPresentationModeActive == false)
        }
    }

    @Test
    func `saving only the display mode does not reset EXIF to the default on a new instance`() {
        let suiteName = "PlaybackSettingsViewModelTests.displayModeDoesNotResetExif"
        let key = "playbackSettings.displayModeDoesNotResetExif"
        let testDefaults = UserDefaults(suiteName: suiteName)!

        do {
            let writerStore = PlaybackSettingsStore(key: key, defaults: testDefaults)
            writerStore.clear()
            var seed = PlaybackSettings()
            seed.autoPlayEnabled = false
            seed.intervalSeconds = 12
            seed.showExif = false
            seed.displayMode = .smartFill
            writerStore.save(seed)

            let writer = PlaybackSettingsViewModel(store: writerStore)
            writer.settings.displayMode = .singlePhoto
        }

        let restoredStore = PlaybackSettingsStore(key: key, defaults: testDefaults)
        defer { restoredStore.clear() }
        let restoredSettings = PlaybackSettingsViewModel(store: restoredStore)
        let loaded = restoredStore.load()

        #expect(loaded?.displayMode == .singlePhoto)
        #expect(loaded?.showExif == false)
        #expect(loaded?.autoPlayEnabled == false)
        #expect(loaded?.intervalSeconds == 12)
        #expect(restoredSettings.settings.showExif == false)
        #expect(restoredSettings.settings.displayMode == .singlePhoto)
    }

    @Test
    func `a non observing player does not apply changed settings live`() async {
        // Debug XCTest takes this path by default; immediate effect can only be asserted in the explicit observer test.
        let testDefaults = UserDefaults(suiteName: "PlaybackSettingsViewModelTests.nonObservingLiveSettings")!
        let store = PlaybackSettingsStore(
            key: "playbackSettings.nonObservingLiveSettings",
            defaults: testDefaults
        )
        store.clear()
        defer { store.clear() }

        let settingsViewModel = PlaybackSettingsViewModel(store: store)
        let existingSlideShow = SlideShowViewModel(
            settingsStore: store,
            observeSettingsChanges: false
        )
        #expect(existingSlideShow.isAutoPlay)
        #expect(existingSlideShow.autoPlayInterval == 5)

        settingsViewModel.settings.autoPlayEnabled = false
        settingsViewModel.settings.intervalSeconds = 12
        settingsViewModel.settings.showExif = false
        settingsViewModel.settings.displayMode = .singlePhoto
        await Task { @MainActor in }.value

        #expect(existingSlideShow.isAutoPlay)
        #expect(existingSlideShow.autoPlayInterval == 5)
        if !PlatformCompat.forceSinglePhotoPlaybackForDebug {
            #expect(existingSlideShow.isSmartFillPresentationModeActive)
        }

        let rereadSlideShow = SlideShowViewModel(
            settingsStore: store,
            observeSettingsChanges: false
        )
        let loaded = store.load()
        #expect(rereadSlideShow.isAutoPlay == false)
        #expect(rereadSlideShow.autoPlayInterval == 12)
        #expect(loaded?.showExif == false)
        #expect(loaded?.displayMode == .singlePhoto)
        if !PlatformCompat.forceSinglePhotoPlaybackForDebug {
            #expect(rereadSlideShow.isSmartFillPresentationModeActive == false)
        }
    }

    @Test
    func `explicitly observing player applies saved settings live immediately`() async {
        // Covers only observeSettingsChanges: true; it does not claim release builds are protected while Debug does not
        // observe by default.
        let testDefaults = UserDefaults(suiteName: "PlaybackSettingsViewModelTests.observingLiveSettings")!
        let store = PlaybackSettingsStore(
            key: "playbackSettings.observingLiveSettings",
            defaults: testDefaults
        )
        store.clear()
        defer { store.clear() }

        let settingsViewModel = PlaybackSettingsViewModel(store: store)
        let existingSlideShow = SlideShowViewModel(
            settingsStore: store,
            observeSettingsChanges: true
        )

        settingsViewModel.settings.autoPlayEnabled = false
        settingsViewModel.settings.intervalSeconds = 12
        settingsViewModel.settings.showExif = false
        settingsViewModel.settings.displayMode = .singlePhoto
        await Task { @MainActor in }.value

        let loaded = store.load()
        #expect(existingSlideShow.isAutoPlay == false)
        #expect(existingSlideShow.autoPlayInterval == 12)
        #expect(loaded?.showExif == false)
        #expect(loaded?.displayMode == .singlePhoto)
        if !PlatformCompat.forceSinglePhotoPlaybackForDebug {
            #expect(existingSlideShow.isSmartFillPresentationModeActive == false)
        }
    }

}

@MainActor
private func makeSettingsViewModelForFilterModeTransition(
    _ mode: DefaultPlaybackMode,
    suiteName: String
) -> (PlaybackSettingsStore, PlaybackSettingsViewModel) {
    let defaults = UserDefaults(suiteName: suiteName)!
    let store = PlaybackSettingsStore(
        key: "playbackSettings.\(suiteName)",
        defaults: defaults
    )
    store.clear()
    var initialSettings = PlaybackSettings()
    initialSettings.defaultPlaybackMode = mode
    store.save(initialSettings)
    return (store, PlaybackSettingsViewModel(store: store))
}

@MainActor
@Suite(.serialized, .sharedRuntimeIsolation)
struct SharedRuntimeIsolationSentinelTests {
    @Test
    func `shared isolation scope restores settings, filter selection, and download state`() async {
        let settingsStore = PlaybackSettingsStore()
        let selectionStore = FilterSelectionStore()
        let downloadManager = AssetsDownloadManager.shared
        let defaults = UserDefaults.standard
        let originalSettings = defaults.object(forKey: "playbackSettings")
        let originalSelection = defaults.object(forKey: "filterSelection")
        let originalAssetStates = downloadManager.assetStates
        let originalAssetPreviewStates = downloadManager.assetPreviewStates
        let originalAssetThumbnailStates = downloadManager.assetThumbnailStates
        let originalAssetURLs = downloadManager.assetURLs
        let originalAssetPreviewURLs = downloadManager.assetPreviewURLs
        let originalAssetThumbnailURLs = downloadManager.assetThumbnailURLs
        let settings = PlaybackSettings()
        let selection = FilterSelection(
            albumIds: ["u04-sentinel-album"],
            personFilters: [PersonFilter(personId: "u04-sentinel-person", matchMode: .normal)]
        )
        let sentinelURL = URL(fileURLWithPath: "/tmp/u04-sentinel.jpg")
        let previewURL = URL(fileURLWithPath: "/tmp/u04-preview.jpg")
        let thumbnailURL = URL(fileURLWithPath: "/tmp/u04-thumbnail.jpg")

        settingsStore.save(settings)
        selectionStore.save(selection)
        downloadManager.assetStates["u04-sentinel"] = .readyToPlay
        downloadManager.assetURLs["u04-sentinel"] = sentinelURL
        downloadManager.assetPreviewStates["u04-preview"] = .readyToPlay
        downloadManager.assetThumbnailStates["u04-thumbnail"] = .readyToPlay
        downloadManager.assetPreviewURLs["u04-preview"] = previewURL
        downloadManager.assetThumbnailURLs["u04-thumbnail"] = thumbnailURL
        defer {
            downloadManager.resetForServerConfigurationChange()
            downloadManager.assetStates = originalAssetStates
            downloadManager.assetPreviewStates = originalAssetPreviewStates
            downloadManager.assetThumbnailStates = originalAssetThumbnailStates
            downloadManager.assetURLs = originalAssetURLs
            downloadManager.assetPreviewURLs = originalAssetPreviewURLs
            downloadManager.assetThumbnailURLs = originalAssetThumbnailURLs
            defaults.set(originalSettings, forKey: "playbackSettings")
            defaults.set(originalSelection, forKey: "filterSelection")
        }

        await ServerConfigurationTestIsolation.runWithSharedRuntimeState {
            PlaybackSettingsStore().clear()
            FilterSelectionStore().clear()
            downloadManager.assetStates.removeAll()
            downloadManager.assetURLs.removeAll()
            downloadManager.assetPreviewStates.removeAll()
            downloadManager.assetThumbnailStates.removeAll()
            downloadManager.assetPreviewURLs.removeAll()
            downloadManager.assetThumbnailURLs.removeAll()
        }

        #expect(settingsStore.load() == settings)
        #expect(selectionStore.load() == selection)
        #expect(downloadManager.assetStates["u04-sentinel"] == .readyToPlay)
        #expect(downloadManager.assetURLs["u04-sentinel"] == sentinelURL)
        #expect(downloadManager.assetPreviewStates["u04-preview"] == .readyToPlay)
        #expect(downloadManager.assetThumbnailStates["u04-thumbnail"] == .readyToPlay)
        #expect(downloadManager.assetPreviewURLs["u04-preview"] == previewURL)
        #expect(downloadManager.assetThumbnailURLs["u04-thumbnail"] == thumbnailURL)
    }

    @Test
    func `shared isolation restores original undecodable persisted values`() async {
        // A dedicated UserDefaults domain prevents app-host startup writes to standard defaults from interfering.
        let defaults = UserDefaults(suiteName: "SharedRuntimeIsolationSentinelTests.undecodable")!
        let originalSettings = defaults.object(forKey: "playbackSettings")
        let originalSelection = defaults.object(forKey: "filterSelection")
        defer {
            defaults.set(originalSettings, forKey: "playbackSettings")
            defaults.set(originalSelection, forKey: "filterSelection")
        }
        let settingsBytes = Data("{invalid-playback".utf8)
        let selectionBytes = Data("{invalid-selection".utf8)
        defaults.set(settingsBytes, forKey: "playbackSettings")
        defaults.set(selectionBytes, forKey: "filterSelection")

        await ServerConfigurationTestIsolation.runWithSharedRuntimeState(defaults: defaults) {
            #expect(defaults.object(forKey: "playbackSettings") == nil)
            #expect(defaults.object(forKey: "filterSelection") == nil)
        }

        #expect(defaults.data(forKey: "playbackSettings") == settingsBytes)
        #expect(defaults.data(forKey: "filterSelection") == selectionBytes)
    }
}
