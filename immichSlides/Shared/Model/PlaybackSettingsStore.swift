//
//  PlaybackSettingsStore.swift
//  immichSlides
//
//  Created by Codex on 2026/3/10.
//

import Foundation

extension Notification.Name {
    static let playbackSettingsDidChange = Notification.Name("PlaybackSettingsStore.didChange")
}

final class PlaybackSettingsStore {
    private let key: String
    private let defaults: UserDefaults
    static let changedSettingsUserInfoKey = "settings"
    static let changedStoreKeyUserInfoKey = "storeKey"

    init(
        key: String = "playbackSettings",
        defaults: UserDefaults = .standard
    ) {
        self.key = key
        self.defaults = defaults
    }

    var notificationScope: String { key }

    func save(_ settings: PlaybackSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(
            name: .playbackSettingsDidChange,
            object: nil,
            userInfo: [
                Self.changedSettingsUserInfoKey: settings,
                Self.changedStoreKeyUserInfoKey: key
            ]
        )
    }

    func load() -> PlaybackSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PlaybackSettings.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

// Whether the one-time playback entry hint has been shown; stored apart from the user's playback preferences so
// UI tests can reset it on its own.
final class PlaybackEntryHintStore {
    private let hasShownPlaybackEntryHintKey = "playbackEntryHint.hasShown"
    private let defaults = UserDefaults.standard

    var hasShownPlaybackEntryHint: Bool {
        defaults.bool(forKey: hasShownPlaybackEntryHintKey)
    }

    func markPlaybackEntryHintShown() {
        defaults.set(true, forKey: hasShownPlaybackEntryHintKey)
    }

    func clear() {
        defaults.removeObject(forKey: hasShownPlaybackEntryHintKey)
    }
}
