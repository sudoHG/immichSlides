import CryptoKit
import Foundation

@main
struct SmartFillPlannerBenchmark {
    private static let aspects: [Double] = [
        0.42, 0.56, 0.66, 0.75, 0.80, 1.00, 1.25, 1.33, 1.50, 1.78, 2.00, 2.40, 3.00
    ]
    private static let sceneCountPerSurface = 100
    private static let candidateCountPerScene = 72
    private static let adversarialSceneIndex = 23

    static func main() {
        let options = BenchmarkOptions(arguments: CommandLine.arguments)
        let corpus = makeCorpus()
        let fingerprint = corpusFingerprint(for: corpus)
        var checksum = 0
        print("corpusFingerprint=\(fingerprint)")

        let phaseAScenario = makeScenario(surface: iPadLandscapeSurface, sceneIndex: adversarialSceneIndex)
        let phaseAStart = DispatchTime.now().uptimeNanoseconds
        let phaseAResult = plan(phaseAScenario)
        let phaseAEnd = DispatchTime.now().uptimeNanoseconds
        let phaseAMs = milliseconds(from: phaseAStart, to: phaseAEnd)

        var samples: [CallSample] = []
        samples.reserveCapacity(corpus.count)
        var distribution = SceneTypeCounter()
        var capped = false
        let benchmarkStart = DispatchTime.now().uptimeNanoseconds
        for scenario in corpus {
            if let maxWallMs = options.maxWallMs,
               milliseconds(from: benchmarkStart, to: DispatchTime.now().uptimeNanoseconds) >= maxWallMs {
                capped = true
                break
            }
            let start = DispatchTime.now().uptimeNanoseconds
            let result = plan(scenario)
            let end = DispatchTime.now().uptimeNanoseconds
            let elapsedMs = milliseconds(from: start, to: end)
            distribution.record(result.sceneType)
            checksum &+= checksumValue(for: result)
            let sample = CallSample(
                elapsedMs: elapsedMs,
                scenario: scenario,
                result: result
            )
            samples.append(sample)
            if options.stream {
                print("call \(sample.outputLine)")
                fflush(stdout)
            }
        }

        let stats = SampleStats(samples: samples.map(\.elapsedMs))
        let slowest = samples.sorted { $0.elapsedMs > $1.elapsedMs }.prefix(5)
        let wallMs = milliseconds(from: benchmarkStart, to: DispatchTime.now().uptimeNanoseconds)
        print(
            "phaseA surfaceKey=\(phaseAScenario.surface.surfaceKey) " +
            "scene=\(phaseAScenario.sceneOrdinal) " +
            "currentAspect=\(aspectText(phaseAScenario.currentAspect)) " +
            "elapsed_ms=\(format(phaseAMs)) " +
            "sceneType=\(phaseAResult.sceneType.rawValue) " +
            "evaluationCount=\(phaseAResult.evaluationCount)"
        )
        print(
            "stats calls=\(samples.count) " +
            "mean_ms=\(format(stats.mean)) " +
            "median_ms=\(format(stats.median)) " +
            "p95_ms=\(format(stats.p95)) " +
            "max_ms=\(format(stats.max)) " +
            "wall_ms=\(format(wallMs)) " +
            "capped=\(capped) " +
            "checksum=\(checksum)"
        )
        print(
            "scene_type_distribution single=\(distribution.single) " +
            "double=\(distribution.double) " +
            "triple=\(distribution.triple) " +
            "fallback=\(distribution.fallback)"
        )
        for (index, sample) in slowest.enumerated() {
            print("slowest_\(index + 1) \(sample.outputLine)")
        }

        if let maxAllowedMs = options.requireMaxMs, stats.max >= maxAllowedMs {
            FileHandle.standardError.write(
                Data("max_ms \(format(stats.max)) exceeded \(format(maxAllowedMs))\n".utf8)
            )
            Foundation.exit(2)
        }
    }

    private static func makeCorpus() -> [BenchmarkScenario] {
        smartFillSurfaces.flatMap { surface in
            (0..<sceneCountPerSurface).map { sceneIndex in
                makeScenario(surface: surface, sceneIndex: sceneIndex)
            }
        }
    }

    private static func makeScenario(
        surface: PlaybackSmartFillSurface,
        sceneIndex: Int
    ) -> BenchmarkScenario {
        let currentAspect = aspects[sceneIndex % aspects.count]
        let currentPixelSize = pixelSize(for: currentAspect)
        let current = candidate(
            reference: "bench-\(surface.surfaceKey)-\(sceneIndex)-current",
            pixelSize: currentPixelSize,
            faceRects: []
        )
        var candidateAspects: [Double] = []
        var candidateFaceFlags: [Bool] = []
        var candidatePixelSizes: [PlaybackPlanningPixelSize] = []
        let lookahead = (0..<candidateCountPerScene).map { candidateIndex in
            let aspect = aspects[(sceneIndex + candidateIndex + 1) % aspects.count]
            let hasFace = (sceneIndex + candidateIndex).isMultiple(of: 2)
            let pixelSize = pixelSize(for: aspect)
            candidateAspects.append(aspect)
            candidateFaceFlags.append(hasFace)
            candidatePixelSizes.append(pixelSize)
            return candidate(
                reference: "bench-\(surface.surfaceKey)-\(sceneIndex)-\(candidateIndex)",
                pixelSize: pixelSize,
                faceRects: hasFace ? [fixedFaceRect] : []
            )
        }
        return BenchmarkScenario(
            surface: surface,
            candidates: [current] + lookahead,
            sceneOrdinal: sceneIndex,
            currentAspect: currentAspect,
            currentPixelSize: currentPixelSize,
            candidateAspects: candidateAspects,
            candidateFaceFlags: candidateFaceFlags,
            candidatePixelSizes: candidatePixelSizes
        )
    }

    private static func plan(_ scenario: BenchmarkScenario) -> PlaybackSmartFillPlannerResult {
        PlaybackSmartFillPlanner.plan(
            PlaybackSmartFillPlannerInput(
                surface: scenario.surface,
                candidates: scenario.candidates,
                protectionSnapshot: .empty,
                policy: .policy(for: scenario.surface),
                playbackSessionSeed: "planner-perf-baseline-v1",
                sceneOrdinal: scenario.sceneOrdinal
            )
        )
    }

    private static func candidate(
        reference: String,
        pixelSize: PlaybackPlanningPixelSize,
        faceRects: [PlaybackPlanningRect]
    ) -> PlaybackSmartFillCandidateSummary {
        PlaybackSmartFillCandidateSummary(
            reference: reference,
            sourceImage: PlaybackPlanningSourceImageSummary(
                assetPixelSize: pixelSize,
                exifPixelSize: pixelSize,
                orientation: "available"
            ),
            faceRects: faceRects,
            subjectRects: faceRects
        )
    }

    private static var fixedFaceRect: PlaybackPlanningRect {
        PlaybackPlanningRect(x: 0.35, y: 0.12, width: 0.30, height: 0.32)
    }

    private static func pixelSize(for aspect: Double) -> PlaybackPlanningPixelSize {
        PlaybackPlanningPixelSize(width: Int((aspect * 1_200).rounded()), height: 1_200)
    }

    private static func corpusFingerprint(for corpus: [BenchmarkScenario]) -> String {
        var payload = ""
        for scenario in corpus {
            let candidateAspects = scenario.candidateAspects.map(aspectText).joined(separator: ",")
            let faceFlags = scenario.candidateFaceFlags.map { $0 ? "1" : "0" }.joined(separator: ",")
            let pixelSizes = scenario.candidatePixelSizes.map(pixelSizeText).joined(separator: ",")
            payload += [
                "surfaceKey=\(scenario.surface.surfaceKey)",
                "currentAspect=\(aspectText(scenario.currentAspect))",
                "candidateAspects=\(candidateAspects)",
                "faceFlags=\(faceFlags)",
                "pixelSizes=\(pixelSizes)"
            ].joined(separator: "|")
            payload += "\n"
        }
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func checksumValue(for result: PlaybackSmartFillPlannerResult) -> Int {
        result.sceneType.rawValue.count
            &+ result.layoutVariant.rawValue.count
            &+ result.ratioPreset.count
            &+ result.slots.count
            &+ result.evaluationCount
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000.0
    }

    private static func aspectText(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func pixelSizeText(_ pixelSize: PlaybackPlanningPixelSize) -> String {
        "\(pixelSize.width)x\(pixelSize.height)"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static var phonePortraitSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 1_179, height: 2_556),
            profile: .iPhone,
            orientation: .portrait
        )
    }

    private static var phoneLandscapeSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2_556, height: 1_179),
            profile: .iPhone,
            orientation: .landscape
        )
    }

    private static var iPadPortraitSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2_048, height: 2_732),
            profile: .iPad,
            orientation: .portrait
        )
    }

    private static var iPadLandscapeSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 2_732, height: 2_048),
            profile: .iPad,
            orientation: .landscape
        )
    }

    private static var appleTVSurface: PlaybackSmartFillSurface {
        PlaybackSmartFillSurface(
            pixelSize: PlaybackPlanningPixelSize(width: 3_840, height: 2_160),
            profile: .appleTV,
            orientation: .landscape
        )
    }

    private static var smartFillSurfaces: [PlaybackSmartFillSurface] {
        [
            phonePortraitSurface,
            phoneLandscapeSurface,
            iPadPortraitSurface,
            iPadLandscapeSurface,
            appleTVSurface
        ]
    }
}

private struct BenchmarkScenario {
    let surface: PlaybackSmartFillSurface
    let candidates: [PlaybackSmartFillCandidateSummary]
    let sceneOrdinal: Int
    let currentAspect: Double
    let currentPixelSize: PlaybackPlanningPixelSize
    let candidateAspects: [Double]
    let candidateFaceFlags: [Bool]
    let candidatePixelSizes: [PlaybackPlanningPixelSize]
}

private struct BenchmarkOptions {
    let requireMaxMs: Double?
    let maxWallMs: Double?
    let stream: Bool

    init(arguments: [String]) {
        requireMaxMs = Self.doubleValue(after: "--require-max-ms", in: arguments)
        maxWallMs = Self.doubleValue(after: "--max-wall-ms", in: arguments)
        stream = arguments.contains("--stream")
    }

    private static func doubleValue(after flag: String, in arguments: [String]) -> Double? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return Double(arguments[index + 1])
    }
}

private struct CallSample {
    let elapsedMs: Double
    let scenario: BenchmarkScenario
    let result: PlaybackSmartFillPlannerResult

    var outputLine: String {
        [
            "elapsed_ms=\(format(elapsedMs))",
            "surfaceKey=\(scenario.surface.surfaceKey)",
            "scene=\(scenario.sceneOrdinal)",
            "currentAspect=\(aspectText(scenario.currentAspect))",
            "sceneType=\(result.sceneType.rawValue)",
            "layoutVariant=\(result.layoutVariant.rawValue)",
            "ratioPreset=\(result.ratioPreset)",
            "evaluationCount=\(result.evaluationCount)",
            "candidateAspects=[\(scenario.candidateAspects.map(aspectText).joined(separator: ","))]"
        ].joined(separator: " ")
    }

    private func aspectText(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct SceneTypeCounter {
    private(set) var single = 0
    private(set) var double = 0
    private(set) var triple = 0
    private(set) var fallback = 0

    mutating func record(_ sceneType: PlaybackSmartFillSceneType) {
        switch sceneType {
        case .single:
            single += 1
        case .double:
            double += 1
        case .triple:
            triple += 1
        case .fallback:
            fallback += 1
        }
    }
}

private struct SampleStats {
    let mean: Double
    let median: Double
    let p95: Double
    let max: Double

    init(samples: [Double]) {
        guard !samples.isEmpty else {
            mean = 0
            median = 0
            p95 = 0
            max = 0
            return
        }
        let sorted = samples.sorted()
        mean = samples.reduce(0, +) / Double(samples.count)
        median = sorted[sorted.count / 2]
        let p95Rank = Int(ceil(Double(sorted.count) * 0.95)) - 1
        p95 = sorted[Swift.max(0, Swift.min(p95Rank, sorted.count - 1))]
        max = sorted[sorted.count - 1]
    }
}
