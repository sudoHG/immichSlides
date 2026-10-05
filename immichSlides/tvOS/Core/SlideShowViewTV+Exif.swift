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
        viewModel.refreshPlaybackRelatedSettings(
            applyExifVisibility: { isExifVisible = $0 },
            applyDebugOverlayVisibility: { isDebugOverlayVisible = $0 }
        )
    }
}
#endif
