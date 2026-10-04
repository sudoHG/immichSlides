// After switching servers, old album/person IDs must disappear from FilterViewModel and the Store; without a
// seed, no fake album may be written.

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.serialized, .sharedRuntimeIsolation)
struct FilterSelectionResetTests {

    @Test
    func `reset removes old album and person ids so a new store instance cannot read them`() {
        let snapshot = FilterSelectionDefaultsSnapshot.captureAndClear()
        defer { snapshot.restore() }

        let viewModel = FilterViewModel()
        viewModel.selection = FilterSelection(
            albumIds: ["old-album"],
            personFilters: [PersonFilter(personId: "old-person", matchMode: .normal)]
        )

        #expect(viewModel.selection.albumIds == ["old-album"])
        #expect(viewModel.selection.personFilters.map(\.personId) == ["old-person"])
        #expect(FilterSelectionStore().load()?.albumIds == ["old-album"])
        #expect(FilterSelectionStore().load()?.personFilters.map(\.personId) == ["old-person"])

        viewModel.resetForServerConfigurationChange()

        #expect(viewModel.selection.albumIds == [])
        #expect(viewModel.selection.personFilters == [])

        let loaded = FilterSelectionStore().load()
        #expect(loaded?.albumIds.contains("old-album") != true)
        #expect(loaded?.personFilters.contains(where: { $0.personId == "old-person" }) != true)
    }

    @Test
    func `reset without a seed environment variable does not write back the ui-test-album-id`() {
        let snapshot = FilterSelectionDefaultsSnapshot.captureAndClear()
        defer { snapshot.restore() }

        #expect(ProcessInfo.processInfo.environment["UI_TEST_SEED_FILTER_SELECTION"] != "1")

        let viewModel = FilterViewModel()
        viewModel.selection = FilterSelection(albumIds: ["old-album"])
        viewModel.resetForServerConfigurationChange()

        #expect(!viewModel.selection.albumIds.contains("ui-test-album-id"))
        #expect(FilterSelectionStore().load()?.albumIds.contains("ui-test-album-id") != true)
    }

    @Test
    func `store clear removes the old album id so a new store instance cannot read it`() {
        let snapshot = FilterSelectionDefaultsSnapshot.captureAndClear()
        defer { snapshot.restore() }

        FilterSelectionStore().save(FilterSelection(albumIds: ["old-album"]))
        #expect(FilterSelectionStore().load()?.albumIds.contains("old-album") == true)

        FilterSelectionStore().clear()

        #expect(FilterSelectionStore().load()?.albumIds.contains("old-album") != true)
    }
}

/// Backs up and restores the `filterSelection` key and UI test seed environment variables so parallel test runs
/// remain isolated.
private struct FilterSelectionDefaultsSnapshot {
    private static let defaultsKey = "filterSelection"
    private static let seedEnvKey = "UI_TEST_SEED_FILTER_SELECTION"
    private static let seedJSONEnvKey = "UI_TEST_FILTER_SELECTION_JSON"

    let storedFilterSelectionData: Data?
    let previousSeed: String?
    let previousSeedJSON: String?

    static func captureAndClear() -> FilterSelectionDefaultsSnapshot {
        let snapshot = FilterSelectionDefaultsSnapshot(
            storedFilterSelectionData: UserDefaults.standard.data(forKey: defaultsKey),
            previousSeed: getenv(seedEnvKey).map { String(cString: $0) },
            previousSeedJSON: getenv(seedJSONEnvKey).map { String(cString: $0) }
        )
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        unsetenv(seedEnvKey)
        unsetenv(seedJSONEnvKey)
        return snapshot
    }

    func restore() {
        if let storedFilterSelectionData {
            UserDefaults.standard.set(storedFilterSelectionData, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        restoreEnv(Self.seedEnvKey, previousSeed)
        restoreEnv(Self.seedJSONEnvKey, previousSeedJSON)
    }

    private func restoreEnv(_ key: String, _ value: String?) {
        if let value {
            _ = setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}
