#if os(tvOS)
import SwiftUI
import UIKit

extension SlideShowViewTV {
    func refreshExifForegroundTone(
        surfaceSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) async {
        guard let asset = visibleExifOverlayAsset else {
            exifForegroundTone = .lightText
            isExifForegroundToneReady = false
            return
        }
        isExifForegroundToneReady = false

        let backdropContext = ExifDisplayedBackdropContext(
            surfaceSize: surfaceSize,
            safeAreaInsets: UIEdgeInsets(
                top: safeAreaInsets.top,
                left: safeAreaInsets.leading,
                bottom: safeAreaInsets.bottom,
                right: safeAreaInsets.trailing
            ),
            exifFrameInSurfaceSpace: exifFrameInSurfaceSpace
        )

        guard backdropContext.isValid else {
            // While the EXIF frame is still zero, use white text and sample after the geometry is written back.

            exifForegroundTone = .lightText
            isExifForegroundToneReady = false
            return
        }

        guard
            ExifForegroundAnalyzer.hasCachedImage(
                assetId: asset.id,
                downloadManager: viewModel.downloadManager
            )
        else {
            // If the image isn't cached yet, don't guess the text color from empty data.

            exifForegroundTone = .lightText
            isExifForegroundToneReady = false
            return
        }

        exifForegroundTone = await ExifForegroundAnalyzer.resolveTone(
            assetId: asset.id,
            downloadManager: viewModel.downloadManager,
            backdropContext: backdropContext,
            profile: .tvOS
        )
        isExifForegroundToneReady = true
    }

    func syncExifOverlayPresentation() {
        syncExifOverlayPresentation(visibleExifOverlayAsset)
    }
    func syncExifOverlayPresentation(_ asset: Asset?) {
        if let asset {
            if isRenderedExifOverlayVisible {
                withAnimation(.easeInOut(duration: PlaybackTransitionContract.imageCrossfadeDuration)) {
                    retainedExifOverlayAsset = asset
                }
            } else {
                retainedExifOverlayAsset = asset
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: PlaybackTransitionContract.imageCrossfadeDuration)) {
                        isRenderedExifOverlayVisible = true
                    }
                }
            }
        } else if isRenderedExifOverlayVisible {
            withAnimation(.easeInOut(duration: PlaybackTransitionContract.imageCrossfadeDuration)) {
                isRenderedExifOverlayVisible = false
            }
        }
    }

    func refreshPlaybackRelatedSettings() {
        // Sync autoplay settings each time playback opens, so the long-lived ViewModel doesn't use stale values.
        viewModel.refreshAutoPlaySettingsFromStore()
        let settings = PlaybackSettingsStore().load() ?? PlaybackSettings()
        isExifVisible = settings.showExif

        isDebugOverlayVisible = PlatformCompat.isPlaybackDebugPanelEnabled && settings.showDebugOverlay

        switch settings.defaultPlaybackMode {
        case .random:
            guard settings.defaultPlaybackMode != viewModel.currentPlaybackMode else { return }
            Task {
                await viewModel.switchPlaybackSource(to: .random)
            }
        case .filtered:
            let selection = FilterSelectionStore().load() ?? FilterSelection()
            // Don't switch to filtered playback without a usable filter, to avoid empty playback.
            guard !selection.isEmpty else { return }

            // If the selection changes during filtered playback, reload right away instead of waiting for a restart.

            let modeChanged = settings.defaultPlaybackMode != viewModel.currentPlaybackMode
            let filteredSelectionChanged = viewModel.shouldReloadFilteredSource(for: selection)
            guard modeChanged || filteredSelectionChanged else { return }

            Task {
                await viewModel.switchPlaybackSource(to: .filtered(selection))
            }
        }
    }
}
#endif
