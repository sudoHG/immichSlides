import Foundation

extension SlideShowViewModel {
    func refreshPlaybackRelatedSettings(
        applyExifVisibility: (Bool) -> Void,
        applyDebugOverlayVisibility: (Bool) -> Void
    ) {
        // Refresh on every playback entry so the long-lived view model does not keep stale settings.
        refreshAutoPlaySettingsFromStore()
        // Preserve the prior view-side read; autoplay refresh uses the injected playbackSettingsStore.
        let settings = PlaybackSettingsStore().load() ?? PlaybackSettings()
        applyExifVisibility(settings.showExif)
        applyDebugOverlayVisibility(PlatformCompat.isPlaybackDebugPanelEnabled && settings.showDebugOverlay)

        switch settings.defaultPlaybackMode {
        case .random:
            guard settings.defaultPlaybackMode != currentPlaybackMode else { return }
            Task {
                await self.switchPlaybackSource(to: .random)
            }
        case .filtered:
            let selection = FilterSelectionStore().load() ?? FilterSelection()
            // Skip filtered playback without a usable filter to avoid an empty slideshow.
            guard !selection.isEmpty else { return }

            // Reload changed filters immediately during filtered playback instead of waiting for a restart.
            let hasModeChanged = settings.defaultPlaybackMode != currentPlaybackMode
            let hasFilteredSelectionChanged = shouldReloadFilteredSource(for: selection)
            guard hasModeChanged || hasFilteredSelectionChanged else { return }

            Task {
                await self.switchPlaybackSource(to: .filtered(selection))
            }
        }
    }
}
