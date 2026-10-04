//
//  PlaybackSettingsViewModel.swift
//  immichSlides
//
//  Created by Codex on 2026/3/10.
//

import Foundation
import Combine

@MainActor
final class PlaybackSettingsViewModel: ObservableObject {
    // Source of UI bindings; didSet persists, and external write-backs must skip it to avoid recursion.
    @Published var settings: PlaybackSettings {
        didSet {
            guard !isApplyingExternalUpdate else { return }
            sanitizeAndSave()
        }
    }

    private let store: PlaybackSettingsStore
    // Prevents the "normalizing assignment" from triggering didSet again and recursing.
    private var isApplyingSanitization = false
    private var isApplyingExternalUpdate = false
    private var settingsChangeObserver: NSObjectProtocol?

    convenience init() {
        self.init(store: PlaybackSettingsStore())
    }

    init(store: PlaybackSettingsStore) {
        self.store = store
        self.settings = store.load() ?? PlaybackSettings()
        sanitizeAndSave()
        settingsChangeObserver = NotificationCenter.default.addObserver(
            forName: .playbackSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // The main-queue observer applies each save synchronously, before the notification returns.
            MainActor.assumeIsolated {
                guard let self,
                    notification.userInfo?[PlaybackSettingsStore.changedStoreKeyUserInfoKey] as? String
                        == self.store.notificationScope,
                    let settings = notification.userInfo?[PlaybackSettingsStore.changedSettingsUserInfoKey]
                        as? PlaybackSettings
                else {
                    return
                }
                self.applyPersistedSettings(settings)
            }
        }
    }

    deinit {
        if let settingsChangeObserver {
            NotificationCenter.default.removeObserver(settingsChangeObserver)
        }
    }

    private func sanitizeAndSave() {
        guard !isApplyingSanitization else { return }

        var normalized = settings
        normalized.intervalSeconds = min(
            PlaybackIntervalPolicy.migratedLegacyInterval(normalized.intervalSeconds),
            60
        )

        if normalized != settings {
            isApplyingSanitization = true
            settings = normalized
            isApplyingSanitization = false
        }

        store.save(settings)
    }

    private func applyPersistedSettings(_ persisted: PlaybackSettings) {
        guard persisted != settings else { return }
        isApplyingExternalUpdate = true
        settings = persisted
        isApplyingExternalUpdate = false
    }

    func enforcePlaybackModeInvariant(
        filterSelectionIsEmpty: Bool,
        isFilterEditorPresented: Bool
    ) {
        // An empty selection inside the editor may be an in-between state while changing albums; fall back only
        // after it closes.
        guard !isFilterEditorPresented,
            settings.defaultPlaybackMode == .filtered,
            filterSelectionIsEmpty
        else { return }

        settings.defaultPlaybackMode = .random
    }
}
