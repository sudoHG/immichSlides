import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct PlaybackIntervalPolicyTests {
    @Test
    func `legacy interval migration raises short values to five seconds and keeps longer values`() {
        #expect(PlaybackIntervalPolicy.minimumInterval == 5)
        #expect(PlaybackIntervalPolicy.migratedLegacyInterval(1) == 5)
        #expect(PlaybackIntervalPolicy.migratedLegacyInterval(3) == 5)
        #expect(PlaybackIntervalPolicy.migratedLegacyInterval(4.9) == 5)
        #expect(PlaybackIntervalPolicy.migratedLegacyInterval(5) == 5)
        #expect(PlaybackIntervalPolicy.migratedLegacyInterval(8) == 8)
        #expect(PlaybackIntervalPolicy.migratedLegacyInterval(120) == 120)
    }
}
