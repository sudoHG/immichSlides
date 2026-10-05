#if os(tvOS)
import SwiftUI
import UIKit

extension SlideShowViewTV {
    func isAcceptedSmartFillMotionTransitionActive(
        in layers: [PlaybackSessionEngine.SceneRenderLayer],
        snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> Bool {
        guard isScenePresentationTransitionActive(snapshot) else { return false }
        let transitionLayers = smartFillTransitionLayers(in: layers)
        guard transitionLayers.contains(where: { $0.role == .outgoing }),
            transitionLayers.contains(where: { $0.role == .incoming })
        else {
            return false
        }
        let scenes = transitionLayers.compactMap { viewModel.scene(for: $0) }
        return scenes.count == transitionLayers.count
            && scenes.allSatisfy { scene in
                switch scene.smartFillReadback?.sceneType {
                case .double, .triple, .single:
                    return true
                case .fallback, nil:
                    return false
                }
            }
    }

    func smartFillTransitionLayers(
        in layers: [PlaybackSessionEngine.SceneRenderLayer]
    ) -> [PlaybackSessionEngine.SceneRenderLayer] {
        layers.filter { layer in
            layer.role == .outgoing || layer.role == .incoming
        }
    }

    @ViewBuilder
    func renderPhoto(in size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / PlaybackViewMetrics.renderSamplingRateHertz, paused: false)) {
            _ in
            let snapshot = viewModel.sceneRenderSnapshot
            let overlayAsset = exifOverlayAsset(in: viewModel.visibleOverlayScene(in: snapshot))
            ZStack {
                if smartFillProductTransitionBlackBacking(
                    in: snapshot.layers,
                    snapshot: snapshot
                ) {
                    Color.black
                        .ignoresSafeArea(.container, edges: .all)
                        .accessibilityHidden(true)
                        .zIndex(-10)
                }
                if !snapshot.layers.isEmpty {
                    ForEach(snapshot.layers) { layer in
                        if let scene = viewModel.scene(for: layer) {
                            let layerIdentity = viewModel.scenePresentationLayerIdentity(for: layer)
                            let visibleFrameCandidate = SceneVisibleFrameCandidate(
                                layerIdentity: layerIdentity,
                                role: layer.role,
                                opacity: layer.opacity,
                                isBarrierComplete: viewModel.isScenePresentationBarrierComplete(for: layer),
                                isSceneRoot: true
                            )
                            SmartFillSceneView(
                                downloadManager: viewModel.downloadManager,
                                scene: scene,
                                isCurrent: PlaybackSessionEngine.ScenePresentationLayerRole.isCurrentForRenderer(
                                    role: layer.role,
                                    opacity: layer.opacity,
                                    hasOutgoingLayer: snapshot.layers.contains { $0.role == .outgoing }
                                ),
                                size: size,
                                safeAreaInsets: safeAreaInsets,
                                renderLayerRole: layer.role,
                                navigationToken: layer.identity.generation,
                                rendererAttemptID: viewModel.scenePresentationRendererAttemptID(for: layer),
                                motionContext: viewModel.motionRuntimeContext(
                                    for: layer,
                                    platform: .tvOS,
                                    isReduceMotionEnabled: accessibilityReduceMotion
                                ),
                                isMotionProbeControlBarVisible: isControlBarVisible,
                                onRendererDecoded: viewModel.rendererDecoded,
                                onRendererFailed: viewModel.rendererFailed
                            )
                            .opacity(layer.opacity)
                            .allowsHitTesting(layer.role == .stable && layer.opacity > 0)
                            .focusable(false)
                            .accessibilityHidden(layer.opacity <= 0 || layer.role == .outgoing)
                            .zIndex(playbackLayerZIndex(for: layer.role))
                            .modifier(
                                SceneVisibleFrameReporterModifier(
                                    candidate: visibleFrameCandidate,
                                    onSceneBecameVisible: viewModel.incomingBecameVisible
                                )
                            )
                        }
                    }
                } else {
                    Text("The slideshow failed to load. Go back, then reopen the slideshow.")
                }
                #if DEBUG
                if PlatformCompat.shouldExposeScenePresentationContractProbeForTesting {
                    // The contract probe reuses the product's displayed-frame
                    // snapshot instead of creating its own clock.
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityElement()
                        .accessibilityIdentifier("slideshow.scenePresentation.contract.summary")
                        .accessibilityLabel(viewModel.scenePresentationContractProbeLabel(for: snapshot))
                        .focusable(false)
                        .allowsHitTesting(false)
                }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: overlayAsset?.id, initial: true) { _, _ in
                syncExifOverlayPresentation(overlayAsset)
            }
            #if DEBUG
            .onPreferenceChange(SmartFillMotionFrameProbePreferenceKey.self) { rows in
                smartFillMotionFrameProbeRows = rows
            }
            #endif
        }
    }
}
#endif
