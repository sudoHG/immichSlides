//
//  PerformanceLiveIntegrationTests.swift
//  immichSlidesTests
//
//  Live server performance tests: require Evidence mode and a configured test server
//  (IMMICH_TEST_* or env.xcconfig). Thresholds can be overridden with IMMICH_PERF_*.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite(.sharedRuntimeIsolation, .enabled(if: isEvidenceRun))
struct PerformanceLiveIntegrationTests {

    private nonisolated static let liveConfiguration = TestServerConfiguration.current
    private nonisolated static let isLiveEnabled = liveConfiguration != nil

    private func configureLiveServer() {

        guard let configuration = Self.liveConfiguration else { return }
        let server = ImmichServer(
            immichURL: ImmichServer.normalizeServerURL(configuration.serverURL),
            immichApiKey: configuration.apiKey
        )
        server.save()
        ImmichAPIService.shared.reloadServerConfiguration()
    }

    private func runWithIsolatedLiveServer<T>(_ body: @escaping () async throws -> T) async rethrows -> T {

        try await ServerConfigurationTestIsolation.run {
            configureLiveServer()
            return try await body()
        }
    }

    private func thresholdMs(_ key: String, defaultValue: Double) -> Double {
        let raw = ProcessInfo.processInfo.environment[key] ?? ""
        if let value = Double(raw), value > 0 {
            return value
        }
        return defaultValue
    }

    private func timedMs(_ block: () async throws -> Void) async rethrows -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        try await block()
        let end = CFAbsoluteTimeGetCurrent()
        return (end - start) * 1000
    }

    private func average(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Double(samples.count)
    }

    private func p95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = Int(ceil(Double(sorted.count) * 0.95)) - 1
        let index = max(0, min(rank, sorted.count - 1))
        return sorted[index]
    }

    private func formatSamples(_ samples: [Double]) -> String {
        samples.map { String(format: "%.1f", $0) }.joined(separator: ", ")
    }

    private func logPerfMetrics(
        testName: String,
        samples: [Double],
        avg: Double,
        p95: Double,
        limit: Double
    ) {
        print("[perf] \(testName)")
        print("[perf] samples (ms) = [\(formatSamples(samples))]")
        print("[perf] average (ms) = \(String(format: "%.1f", avg))")
        print("[perf] P95 (ms) = \(String(format: "%.1f", p95))")
        print("[perf] threshold (ms) = \(String(format: "%.1f", limit))")
    }

    @Test(.enabled(if: isLiveEnabled))
    func `resolver builds a 100 asset playback pool within the time threshold`() async throws {

        try await runWithIsolatedLiveServer {
            let api = ImmichAPIService.shared
            let resolver = PlaybackPoolResolver(apiService: api)
            let people = try await api.getAllPeople(size: 10)
            let personId = try #require(people.first?.id)

            let selection = FilterSelection(
                albumIds: [],
                personFilters: [PersonFilter(personId: personId, matchMode: .normal)],
                tagIds: [],
                rating: nil,
                isFavorite: nil
            )

            _ = try await resolver.resolve(selection: selection, targetCount: 100)

            var samples: [Double] = []
            for _ in 0..<5 {
                let ms = try await timedMs {
                    _ = try await resolver.resolve(selection: selection, targetCount: 100)
                }
                samples.append(ms)
            }

            let avg = average(samples)
            let p95Value = p95(samples)
            let limit = thresholdMs("IMMICH_PERF_RESOLVE_MAX_MS", defaultValue: 4000)

            logPerfMetrics(
                testName: "Playback pool build (target 100 assets)",
                samples: samples,
                avg: avg,
                p95: p95Value,
                limit: limit
            )

            #expect(avg <= limit)
        }
    }

    @Test(.enabled(if: isLiveEnabled))
    @MainActor
    func `preparing initial assets for the first frame stays within the time threshold`() async throws {

        await runWithIsolatedLiveServer {
            var samples: [Double] = []
            for _ in 0..<3 {
                let vm = SlideShowViewModel(source: .random)
                let ms = await timedMs {
                    await vm.prepareInitialAssets()
                }
                #expect(vm.didFirstPreload)
                #expect(vm.assets.count > 0)
                samples.append(ms)
            }

            let avg = average(samples)
            let p95Value = p95(samples)
            let limit = thresholdMs("IMMICH_PERF_FIRST_FRAME_MAX_MS", defaultValue: 5000)

            logPerfMetrics(
                testName: "First frame preparation (prepareInitialAssets)",
                samples: samples,
                avg: avg,
                p95: p95Value,
                limit: limit
            )

            #expect(avg <= limit)
        }
    }

    @Test(.enabled(if: isLiveEnabled))
    @MainActor
    func `loading more assets incrementally stays within the time threshold`() async throws {

        await runWithIsolatedLiveServer {
            var samples: [Double] = []
            for _ in 0..<3 {
                let vm = SlideShowViewModel(source: .random)
                await vm.loadAssets()
                #expect(vm.assets.count > 0)

                let ms = await timedMs {
                    await vm.loadMoreAssets()
                }
                #expect(vm.assets.count > 0)
                samples.append(ms)
            }

            let avg = average(samples)
            let p95Value = p95(samples)
            let limit = thresholdMs("IMMICH_PERF_LOAD_MORE_MAX_MS", defaultValue: 5000)

            logPerfMetrics(
                testName: "Incremental load (loadMoreAssets)",
                samples: samples,
                avg: avg,
                p95: p95Value,
                limit: limit
            )

            #expect(avg <= limit)
        }
    }
}
