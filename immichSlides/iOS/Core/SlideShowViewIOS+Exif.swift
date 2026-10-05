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
            #if DEBUG
            exifSamplingDebugSnapshot = nil
            #endif
            return
        }

        #if DEBUG
        if shouldShowExifSamplingDebugOverlay {
            exifSamplingDebugSnapshot = nil
        }
        #endif

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
            #if DEBUG
            exifSamplingDebugSnapshot = nil
            #endif
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
            #if DEBUG
            exifSamplingDebugSnapshot = nil
            #endif
            return
        }

        exifForegroundTone = await ExifForegroundAnalyzer.resolveTone(
            assetId: asset.id,
            downloadManager: viewModel.downloadManager,
            backdropContext: backdropContext,
            profile: .iOS
        )

        #if DEBUG
        if shouldShowExifSamplingDebugOverlay {
            exifSamplingDebugSnapshot = await ExifForegroundAnalyzer.debugSnapshot(
                assetId: asset.id,
                downloadManager: viewModel.downloadManager,
                backdropContext: backdropContext
            )
        } else {
            exifSamplingDebugSnapshot = nil
        }
        #endif
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
        viewModel.refreshPlaybackRelatedSettings(
            applyExifVisibility: { isExifVisible = $0 },
            applyDebugOverlayVisibility: { isDebugOverlayVisible = $0 }
        )
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
