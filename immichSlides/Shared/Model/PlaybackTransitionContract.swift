//
//  PlaybackTransitionContract.swift
//  immichSlides
//
//  Pure-value types for the playback transition contract; the state machine belongs to PlaybackSessionEngine.
//

import Foundation

enum PlaybackTransitionContract {
    static let imageCrossfadeDuration: TimeInterval = 0.55
}

struct PlaybackVisibleOverlayState: Equatable {
    let ownerSceneId: String
    let ownerPrimaryAssetId: String?
}
