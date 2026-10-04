//
//  PlaybackIntervalPolicy.swift
//  immichSlides
//
//  Turns the configured interval into scene lifecycle seconds; only raises it to the 5-second floor and keeps
//  longer intervals as they are.
//

import Foundation

enum PlaybackIntervalPolicy {
    nonisolated static let minimumInterval: TimeInterval = 5

    /// Only raises the floor; longer intervals are kept as is so the policy does not override the user's choice.
    nonisolated static func normalizedInterval(_ interval: TimeInterval) -> TimeInterval {
        max(minimumInterval, interval)
    }

    /// Migrated legacy persisted intervals use the same floor.
    nonisolated static func migratedLegacyInterval(_ interval: TimeInterval) -> TimeInterval {
        normalizedInterval(interval)
    }
}
