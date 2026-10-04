//
//  SlideItemView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/26.
//

import SwiftUI
import SDWebImageSwiftUI

struct SlideItemView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @ObservedObject var downloadManager: AssetsDownloadManager
    let asset: Asset
    let isCurrent: Bool
    let size: CGSize
    let safeAreaInsets: EdgeInsets
    let sceneId: String
    let renderLayerRole: PlaybackSessionEngine.ScenePresentationLayerRole
    let navigationToken: UUID
    let diagnosticsModeRawValue: String
    let motionContext: MotionRuntimeContext?
    let rendererIdentity: SceneRendererIdentity
    let onRendererDecoded: (SceneRendererIdentity) -> Void
    let onRendererFailed: (SceneRendererIdentity) -> Void

    #if DEBUG
    @State private var backgroundLifecycleRequestId: String?
    @State private var fullsizeLifecycleRequestId: String?
    #endif

    var body: some View {
        // Width and height include the Safe Area so the background covers the notch and the bottom bar.
        let fullWidth = size.width + safeAreaInsets.leading + safeAreaInsets.trailing
        let fullHeight = size.height + safeAreaInsets.top + safeAreaInsets.bottom
        // After expanding, offset in the opposite direction, otherwise the background is not centered.
        let backgroundOffsetX = (safeAreaInsets.trailing - safeAreaInsets.leading) / 2
        let backgroundOffsetY = (safeAreaInsets.bottom - safeAreaInsets.top) / 2

        let observedFullsizeState = downloadManager.assetStates[asset.id] ?? .notStarted
        let fullsizeState = Self.shouldForceLoadingForUITests ? .downloading : observedFullsizeState
        let previewState = downloadManager.assetPreviewStates[asset.id] ?? .notStarted
        let singlePhotoTransform =
            motionContext.map { context in
                SceneAnimationProfile(lifecycle: context.lifecycle).singlePhotoTransform(
                    direction: Self.animationDirection(sceneId: sceneId, assetId: asset.id),
                    activeTime: context.motionActiveTime,
                    isMotionEnabled: context.isMotionEnabled,
                    reduceMotionEnabled: accessibilityReduceMotion || context.reduceMotionEnabled
                )
            } ?? .identity

        ZStack {
            // Wait for fullsize; preview is only the blurred background and must not cover a ready original.

            if Self.shouldRenderPhoto(fullsizeState: fullsizeState, previewState: previewState) {

                if let backgroundURL = backgroundURL(
                    fullsizeState: fullsizeState,
                    previewState: previewState
                ),
                    let modifier = ImmichRequestModifier.create()
                {
                    let requestContext: [SDWebImageContextOption: Any] = [
                        .downloadRequestModifier: modifier
                    ]
                    WebImage(url: backgroundURL, context: requestContext)
                        .onSuccess { image, _, cacheType in
                            #if DEBUG
                            downloadManager.recordRendererImageSuccessForDiagnostics(
                                requestId: backgroundLifecycleRequestId,
                                source: .rendererSingleBackground,
                                assetId: asset.id,
                                size: .fullsize,
                                mode: PlaybackImageRequestLifecycleMode(rawValue: diagnosticsModeRawValue) ?? .single,
                                role: PlaybackImageRequestLifecycleRole(renderLayerRole: renderLayerRole),
                                navigationToken: navigationToken,
                                sceneId: sceneId,
                                url: backgroundURL,
                                context: requestContext,
                                cacheType: cacheType,
                                imagePixelWidth: image.cgImage?.width,
                                imagePixelHeight: image.cgImage?.height
                            )
                            #endif
                        }
                        .resizable()
                        .scaledToFill()
                        .frame(width: fullWidth, height: fullHeight)
                        .blur(radius: 50)
                        .clipped()
                        .onAppear {
                            #if DEBUG
                            backgroundLifecycleRequestId = recordRendererRequestForDiagnostics(
                                source: .rendererSingleBackground,
                                url: backgroundURL,
                                context: requestContext
                            )
                            #endif
                        }
                } else {
                    Color.black
                }

                Rectangle()
                    .fill(.regularMaterial)
                    .opacity(0.05)
                    .frame(width: fullWidth, height: fullHeight)

                if let fullsizeURL = downloadManager.findURL(assetId: asset.id, size: .fullsize),
                    let modifier = ImmichRequestModifier.create()
                {
                    let requestContext: [SDWebImageContextOption: Any] = [
                        .downloadRequestModifier: modifier
                    ]
                    WebImage(url: fullsizeURL, context: requestContext)
                        .onSuccess { image, _, cacheType in
                            #if DEBUG
                            downloadManager.recordRendererImageSuccessForDiagnostics(
                                requestId: fullsizeLifecycleRequestId,
                                source: .rendererSingleFullsize,
                                assetId: asset.id,
                                size: .fullsize,
                                mode: PlaybackImageRequestLifecycleMode(rawValue: diagnosticsModeRawValue) ?? .single,
                                role: PlaybackImageRequestLifecycleRole(renderLayerRole: renderLayerRole),
                                navigationToken: navigationToken,
                                sceneId: sceneId,
                                url: fullsizeURL,
                                context: requestContext,
                                cacheType: cacheType,
                                imagePixelWidth: image.cgImage?.width,
                                imagePixelHeight: image.cgImage?.height
                            )
                            if isCurrent {
                                downloadManager.recordRendererImageConsumedForDiagnostics(
                                    requestId: fullsizeLifecycleRequestId
                                )
                            }
                            #endif
                            onRendererDecoded(rendererIdentity)
                        }
                        .onFailure { _ in
                            onRendererFailed(rendererIdentity)
                        }
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(CGFloat(singlePhotoTransform.scale))
                        .offset(singlePhotoTransform.translationInSlot)
                        .onAppear {
                            #if DEBUG
                            fullsizeLifecycleRequestId = recordRendererRequestForDiagnostics(
                                source: .rendererSingleFullsize,
                                url: fullsizeURL,
                                context: requestContext
                            )
                            #endif
                        }
                }
            } else if isCurrent {
                let blockingState = fullsizeState
                let statusMessage: String = {
                    switch blockingState {
                    case .failed:
                        return String(localized: "Failed to fetch original image URL")
                    case .failedToDownload:
                        return String(localized: "Failed to download original image")
                    default:
                        return String(localized: "Loading...")
                    }
                }()

                ZStack {
                    // For failure/loading, lay a dark scrim first so the text stays readable over any photo.

                    Color.black.opacity(0.66)
                        .frame(width: fullWidth, height: fullHeight)
                    if blockingState == .failed || blockingState == .failedToDownload {

                        SlideFailurePlaceholderView(
                            title: String(localized: "This photo can't be loaded right now"),
                            detail: statusMessage
                        )
                        .frame(maxWidth: min(fullWidth * 0.72, 760))
                        .padding(.horizontal, 28)
                    } else {
                        // When not failed, only show loading; do not expose download stages on the playback screen.

                        SlidePlaybackLoadingView(style: .fullscreen)
                    }
                }
            } else {
                Color.clear
            }

        }
        .frame(width: fullWidth, height: fullHeight)
        .offset(x: backgroundOffsetX, y: backgroundOffsetY)
        .allowsHitTesting(isCurrent)  // Only the current item takes taps; prerendered layers do not steal events.
        .zIndex(isCurrent ? 1 : 0)
        .onChange(of: fullsizeState, initial: true) { _, state in
            if state == .failed || state == .failedToDownload {
                onRendererFailed(rendererIdentity)
            }
        }

    }

    // Only fullsize readiness matters; show the original even if the preview failed.

    static func shouldRenderPhoto(
        fullsizeState: AssetStates,
        previewState: AssetStates
    ) -> Bool {
        let _ = previewState
        return fullsizeState == .readyToPlay
    }

    // Prefer preview for the blurred backdrop; fall back to fullsize when preview is unavailable.

    private func backgroundURL(
        fullsizeState: AssetStates,
        previewState: AssetStates
    ) -> URL? {
        if previewState == .readyToPlay,
            let previewURL = downloadManager.findURL(assetId: asset.id, size: .preview)
        {
            return previewURL
        }

        guard fullsizeState == .readyToPlay else {
            return nil
        }
        return downloadManager.findURL(assetId: asset.id, size: .fullsize)
    }

    private static func animationDirection(sceneId: String, assetId: String) -> SceneAnimationDirection {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in "\(sceneId)|\(assetId)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash.isMultiple(of: 2) ? .zoomIn : .zoomOut
    }

    private static var shouldForceLoadingForUITests: Bool {
        #if DEBUG
        // Only DEBUG UI tests force the loading state; Release never reads this switch.

        ProcessInfo.processInfo.environment["UI_TEST_FORCE_SLIDEITEM_LOADING"] == "1"
        #else
        false
        #endif
    }

    #if DEBUG
    private func recordRendererRequestForDiagnostics(
        source: PlaybackImageRequestLifecycleSource,
        url: URL,
        context: [SDWebImageContextOption: Any]
    ) -> String? {
        downloadManager.recordRendererImageRequestForDiagnostics(
            source: source,
            assetId: asset.id,
            size: .fullsize,
            mode: PlaybackImageRequestLifecycleMode(rawValue: diagnosticsModeRawValue) ?? .single,
            role: PlaybackImageRequestLifecycleRole(renderLayerRole: renderLayerRole),
            navigationToken: navigationToken,
            sceneId: sceneId,
            url: url,
            context: context,
            contextHash: "SlideItemView|\(source.rawValue)|downloadRequestModifier"
        )
    }
    #endif
}

#if DEBUG
extension PlaybackImageRequestLifecycleRole {
    init(renderLayerRole: PlaybackSessionEngine.ScenePresentationLayerRole) {
        switch renderLayerRole {
        case .stable:
            self = .current
        case .incoming:
            self = .incoming
        case .outgoing:
            self = .outgoing
        }
    }

    static func smartFillRendererRole(
        isCurrent: Bool,
        renderLayerRole: PlaybackSessionEngine.ScenePresentationLayerRole
    ) -> Self {
        if isCurrent {
            return .current
        }
        return Self(renderLayerRole: renderLayerRole)
    }
}
#endif

private struct SlideFailurePlaceholderView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
                .shadow(color: .black.opacity(0.26), radius: 8, x: 0, y: 3)

            Text(title)
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

            Text(detail)
                .font(.system(size: 20, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.88))

            Text(LocalizedStringKey("The app will retry automatically, or you can skip to the next photo."))
                .font(.system(size: 17, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)

        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 22, x: 0, y: 10)
    }
}

#Preview {
    let navigationToken = UUID()
    SlideItemView(
        downloadManager: AssetsDownloadManager.shared,
        asset: Asset.previewAssets[2],
        isCurrent: true,
        size: CGSize(width: 834, height: 1194),
        safeAreaInsets: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0),
        sceneId: "preview",
        renderLayerRole: .stable,
        navigationToken: navigationToken,
        diagnosticsModeRawValue: "single",
        motionContext: nil,
        rendererIdentity: SceneRendererIdentity(
            generation: navigationToken,
            sceneID: "preview",
            slotID: nil,
            assetID: Asset.previewAssets[2].id
        ),
        onRendererDecoded: { _ in },
        onRendererFailed: { _ in }
    )

}
