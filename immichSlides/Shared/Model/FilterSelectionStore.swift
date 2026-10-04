//
//  FilterSelectionStore.swift
//  immichSlides
//
//  Created by sudoHG on 2026/2/8.
//

import Foundation

final class FilterSelectionStore {
    private let key = "filterSelection"
    private let defaults = UserDefaults.standard

    // UI tests can inject a non-empty filter; the default is a fake album ID, and full JSON goes through
    // UI_TEST_FILTER_SELECTION_JSON.

    private static let defaultUITestSeedSelection = FilterSelection(albumIds: ["ui-test-album-id"])

    private static var shouldSeedUITestSelection: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard env["UI_TEST_SEED_FILTER_SELECTION"] == "1" else {
            return false
        }

        // The seed only applies in XCTest processes, so a normal Debug run never writes a fake filter by mistake.

        return ImmichServer.isRunningXCTest
        #else
        return false
        #endif
    }

    func save(_ selection: FilterSelection) {

        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: key)
    }

    func load() -> FilterSelection? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FilterSelection.self, from: data)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }

    @discardableResult
    func seedUITestSelectionIfRequestedForTesting() -> FilterSelection? {
        guard Self.shouldSeedUITestSelection else { return nil }

        let selection = Self.uiTestSeedSelectionFromEnvironment() ?? Self.defaultUITestSeedSelection
        save(selection)
        return selection
    }

    private static func uiTestSeedSelectionFromEnvironment() -> FilterSelection? {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        guard let rawJSON = env["UI_TEST_FILTER_SELECTION_JSON"],
            !rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let data = rawJSON.data(using: .utf8)
        else {
            return nil
        }

        return try? JSONDecoder().decode(FilterSelection.self, from: data)
        #else
        return nil
        #endif
    }
}
