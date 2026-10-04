#if os(iOS)
import SwiftUI
import UIKit

extension SlideShowViewIOS {
    func refreshExifForegroundTone(
        surfaceSize: CGSize,
        safeAreaInsets: EdgeInsets
    ) async {
        guard let asset = visibleExifOverlayAsset else {
            exifForegroundTone = .lightText
            exifSamplingDebugSnapshot = nil
            return
        }

        if shouldShowExifSamplingDebugOverlay {
            exifSamplingDebugSnapshot = nil
        }

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

            exifForegroundTone = .lightText
            exifSamplingDebugSnapshot = nil
            return
        }

        guard
            ExifForegroundAnalyzer.hasCachedImage(
                assetId: asset.id,
                downloadManager: viewModel.downloadManager
            )
        else {
            // Image not cached yet: do not guess the text color from empty data; rerun when the download state changes.

            exifForegroundTone = .lightText
            exifSamplingDebugSnapshot = nil
            return
        }

        exifForegroundTone = await ExifForegroundAnalyzer.resolveTone(
            assetId: asset.id,
            downloadManager: viewModel.downloadManager,
            backdropContext: backdropContext,
            profile: .iOS
        )

        if shouldShowExifSamplingDebugOverlay {
            exifSamplingDebugSnapshot = await ExifForegroundAnalyzer.debugSnapshot(
                assetId: asset.id,
                downloadManager: viewModel.downloadManager,
                backdropContext: backdropContext
            )
        } else {
            exifSamplingDebugSnapshot = nil
        }
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
        // Sync autoplay settings on every playback entry so the long-lived ViewModel does not use stale values.
        viewModel.refreshAutoPlaySettingsFromStore()
        let settings = PlaybackSettingsStore().load() ?? PlaybackSettings()
        isExifVisible = settings.showExif

        isDebugOverlayVisible = PlatformCompat.isPlaybackDebugPanelEnabled && settings.showDebugOverlay

        switch settings.defaultPlaybackMode {
        case .random:
            // When the default becomes shuffle, switch source only if not already shuffling.
            guard settings.defaultPlaybackMode != viewModel.currentPlaybackMode else { return }
            Task {
                await viewModel.switchPlaybackSource(to: .random)
            }
        case .filtered:
            let selection = FilterSelectionStore().load() ?? FilterSelection()
            // Without a usable filter, do not switch to filtered playback, to avoid an empty slideshow.
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

    var exifHorizontalPadding: CGFloat {
        if isPhone { return isCompactHeight ? 10 : 14 }
        return 30
    }

    func exifTopPadding(for safeAreaInsets: EdgeInsets) -> CGFloat {
        if isPhone {
            // Add an offset to the top safe area so the Dynamic Island does not cover EXIF.
            let minimumTopInset: CGFloat = isCompactHeight ? 24 : 52
            return max(safeAreaInsets.top, minimumTopInset) + (isCompactHeight ? 6 : 10)
        }
        return 30
    }

    func roundedSamplingValue(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }
}
#endif
