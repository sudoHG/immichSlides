#if os(iOS)
import SwiftUI
import UIKit

extension SlideShowViewIOS {
    private func playbackLayerZIndex(
        for role: PlaybackSessionEngine.ScenePresentationLayerRole
    ) -> Double {
        switch role {
        case .outgoing:
            return 0
        case .stable, .incoming:
            return 1
        }
    }

    func isScenePresentationTransitionActive(
        _ snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> Bool {
        snapshot.underlyingPhase == .transition || snapshot.underlyingPhase == .incomingFromLoading
    }

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
        return scenes.count == transitionLayers.count && scenes.allSatisfy(isAcceptedSmartFillMotionScene)
    }

    func smartFillProductTransitionBlackBacking(
        in layers: [PlaybackSessionEngine.SceneRenderLayer],
        snapshot: PlaybackSessionEngine.SceneRenderSnapshot
    ) -> Bool {
        isSmartFillProductTransitionActive(in: layers, snapshot: snapshot)
    }

    func isSmartFillProductTransitionActive(
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
        return
            transitionLayers
            .compactMap { viewModel.scene(for: $0) }
            .contains(where: isSmartFillProductScene)
    }

    func smartFillTransitionLayers(
        in layers: [PlaybackSessionEngine.SceneRenderLayer]
    ) -> [PlaybackSessionEngine.SceneRenderLayer] {
        layers.filter { layer in
            layer.role == .outgoing || layer.role == .incoming
        }
    }

    private func isAcceptedSmartFillMotionScene(_ scene: PlaybackScene) -> Bool {
        switch scene.smartFillReadback?.sceneType {
        case .double, .triple, .single:
            return true
        case .fallback, nil:
            return false
        }
    }

    private func isSmartFillProductScene(_ scene: PlaybackScene) -> Bool {
        scene.smartFillReadback != nil || viewModel.isSmartFillPresentationModeActive
    }

    func smartFillProductSceneTypeProbeValue(for scene: PlaybackScene) -> String {
        switch scene.smartFillReadback?.sceneType {
        case .double:
            return "double"
        case .triple:
            return "triple"
        case .single:
            return "single"
        case .fallback:
            return "fallback"
        case nil:
            return "legacy"
        }
    }

    func smartFillProductSceneScopeProbeValue(for scene: PlaybackScene) -> String {
        if isAcceptedSmartFillMotionScene(scene) {
            return "acceptedMotion"
        }
        if scene.smartFillReadback == nil, viewModel.isSmartFillPresentationModeActive {
            return "smartFillLegacyNoMotion"
        }
        if isSmartFillProductScene(scene) {
            return "smartFillNoMotion"
        }
        return "legacy"
    }

    @ViewBuilder
    func renderPhoto(in size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { _ in
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
                                    platform: smartFillMotionPlatform,
                                    isReduceMotionEnabled: accessibilityReduceMotion
                                ),
                                isMotionProbeControlBarVisible: isControlBarVisible,
                                onRendererDecoded: viewModel.rendererDecoded,
                                onRendererFailed: viewModel.rendererFailed
                            )
                            .opacity(layer.opacity)
                            .allowsHitTesting(layer.role == .stable && layer.opacity > 0)
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
                if ProcessInfo.processInfo.environment["UI_TEST_SCENE_PRESENTATION_CONTRACT_PROBE"] == "1" {
                    // The read-only probe must use the same clock as the autoplay TimelineView,
                    // so root accessibility does not report stale progress.

                    Button(action: {}) {
                        // localization-audit: Stable UI test probe contract.
                        Text(verbatim: "scene-presentation-frame-synchronized-probe")
                            .font(.system(size: 1))
                    }
                    .buttonStyle(.plain)
                    .opacity(0.01)
                    .accessibilityElement()
                    .accessibilityIdentifier("slideshow.scenePresentation.frameSynchronized.summary")
                    .accessibilityLabel(viewModel.scenePresentationContractProbeLabel(for: snapshot))
                    .allowsHitTesting(false)
                }
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: overlayAsset?.id, initial: true) { _, _ in
                syncExifOverlayPresentation(overlayAsset)
            }
            .onPreferenceChange(SmartFillMotionFrameProbePreferenceKey.self) { rows in
                smartFillMotionFrameProbeRows = rows
                #if DEBUG
                appendSmartFillMotionTraceSampleIfNeeded(rows: rows)
                #endif
            }
        }
    }
}
#endif
