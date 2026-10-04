//
//  PlaybackImageCachePolicyTests.swift
//  immichSlidesTests
//
//  Verifies that the playback image cache residency policy does not revert to the unlimited defaults.
//

import Foundation
import SDWebImage
import Testing
@testable import immichSlides

@MainActor
@Suite
struct PlaybackImageCachePolicyTests {

    @Test
    func `playback image cache sets explicit memory cost and count limits`() {
        let cache = SDImageCache(namespace: "PlaybackImageCachePolicyTests-\(UUID().uuidString)")

        PlaybackImageCachePolicy.apply(to: cache)

        #expect(cache.config.maxMemoryCost == PlaybackImageCachePolicy.memoryCostLimitBytes)
        #expect(cache.config.maxMemoryCount == PlaybackImageCachePolicy.memoryCountLimit)
        #expect(PlaybackImageCachePolicy.memoryCostLimitBytes == 192 * 1024 * 1024)
        #expect(PlaybackImageCachePolicy.memoryCountLimit == 48)
    }
}
