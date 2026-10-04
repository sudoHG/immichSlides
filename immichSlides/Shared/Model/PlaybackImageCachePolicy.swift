//
//  PlaybackImageCachePolicy.swift
//  immichSlides
//

import Foundation
import SDWebImage

enum PlaybackImageCachePolicy {
    static let memoryCostLimitBytes: UInt = 192 * 1024 * 1024
    static let memoryCountLimit: UInt = 48

    static func apply(to cache: SDImageCache) {
        cache.config.maxMemoryCost = memoryCostLimitBytes
        cache.config.maxMemoryCount = memoryCountLimit
    }
}
