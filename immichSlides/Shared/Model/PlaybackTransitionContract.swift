//
//  PlaybackTransitionContract.swift
//  immichSlides
//
//  Pure-value types for the playback transition contract; the state machine belongs to PlaybackSessionEngine.
//

import Foundation

enum PlaybackTransitionContract {
    static let imageCrossfadeDuration: TimeInterval = 0.55
    // Leave a buffer after the animation so the outgoing layer is not torn down while SwiftUI is still finishing.
    static let transitionCompletionDelay: TimeInterval = imageCrossfadeDuration + 0.08
    static var transitionCompletionNanoseconds: UInt64 {
        UInt64(transitionCompletionDelay * 1_000_000_000)
    }
}

enum PlaybackTransitionPhase: Equatable {
    case settled(sceneId: String)
    case animating(transitionId: UUID, fromSceneId: String, toSceneId: String)
}

struct PlaybackRenderLayer: Identifiable {
    enum Role: Equatable {
        case settled
        case outgoing
        case incoming
        case prerender
    }

    let id: String
    let scene: PlaybackScene
    let role: Role
    let isInteractive: Bool
}

struct PlaybackVisibleOverlayState: Equatable {
    let ownerSceneId: String
    let ownerPrimaryAssetId: String?
}
