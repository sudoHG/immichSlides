//
//  ExifForegroundAnalyzerPerformanceTests.swift
//  immichSlidesTests
//
//  Compares the run time of the three EXIF text-color algorithms; does not assert millisecond thresholds.
//

import Foundation
import Testing
import UIKit
@testable import immichSlides

#if os(iOS)

@Suite(.enabled(if: isEvidenceRun))
@MainActor
struct ExifForegroundAnalyzerPerformanceTests {

    private func timedMs(_ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
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
        samples.map { String(format: "%.2f", $0) }.joined(separator: ", ")
    }

    // Build a large image, bright on top and dark below, so its size and blur pipeline resemble the real playback page.

    private func makeBenchmarkImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3024, height: 4032))
        return renderer.image { context in
            let cgContext = context.cgContext
            let fullRect = CGRect(x: 0, y: 0, width: 3024, height: 4032)

            let skyColors =
                [
                    UIColor(red: 0.90, green: 0.94, blue: 0.98, alpha: 1).cgColor,
                    UIColor(red: 0.82, green: 0.88, blue: 0.95, alpha: 1).cgColor
                ] as CFArray
            let skyGradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: skyColors,
                locations: [0.0, 1.0]
            )

            if let skyGradient {
                cgContext.drawLinearGradient(
                    skyGradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: 2200),
                    options: []
                )
            }

            cgContext.setFillColor(UIColor(red: 0.22, green: 0.34, blue: 0.19, alpha: 1).cgColor)
            cgContext.fillEllipse(in: CGRect(x: -120, y: 1800, width: 1850, height: 1200))

            cgContext.setFillColor(UIColor(red: 0.15, green: 0.25, blue: 0.13, alpha: 1).cgColor)
            cgContext.fillEllipse(in: CGRect(x: 980, y: 1700, width: 2100, height: 1450))

            cgContext.setFillColor(UIColor(red: 0.27, green: 0.30, blue: 0.24, alpha: 1).cgColor)
            cgContext.fill(CGRect(x: 0, y: 2800, width: fullRect.width, height: 520))

            cgContext.setFillColor(UIColor(red: 0.10, green: 0.18, blue: 0.08, alpha: 1).cgColor)
            cgContext.fill(CGRect(x: 0, y: 3320, width: fullRect.width, height: 712))
        }
    }

    // Build controlled samples from top/bottom colors, because EXIF is pinned to the top right.

    @Test
    func `displayed-backdrop sampling overhead is measurable against the legacy algorithm`() throws {
        let image = makeBenchmarkImage()
        let cgImage = try #require(image.cgImage)

        // The geometry only needs the right order of magnitude, enough to reach Safe Area, the local frame and
        // aspect fill.

        let backdropContext = ExifDisplayedBackdropContext(
            surfaceSize: CGSize(width: 393, height: 852),
            safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
            exifFrameInSurfaceSpace: CGRect(x: 228, y: 74, width: 150, height: 78)
        )

        let warmupIterations = 5
        for _ in 0..<warmupIterations {
            _ = ExifForegroundAnalyzer.legacyToneForBenchmark(from: cgImage)
            _ = ExifForegroundAnalyzer.displayedBackdropToneForBenchmark(
                from: cgImage,
                backdropContext: backdropContext
            )
        }

        var legacySamples: [Double] = []
        var displayedBackdropAverageSamples: [Double] = []
        var displayedBackdropReadabilitySamples: [Double] = []

        let benchmarkIterations = 30
        for _ in 0..<benchmarkIterations {
            legacySamples.append(
                timedMs {
                    _ = ExifForegroundAnalyzer.legacyToneForBenchmark(from: cgImage)
                }
            )

            displayedBackdropAverageSamples.append(
                timedMs {
                    _ = ExifForegroundAnalyzer.displayedBackdropAverageToneForBenchmark(
                        from: cgImage,
                        backdropContext: backdropContext
                    )
                }
            )

            displayedBackdropReadabilitySamples.append(
                timedMs {
                    _ = ExifForegroundAnalyzer.displayedBackdropToneForBenchmark(
                        from: cgImage,
                        backdropContext: backdropContext
                    )
                }
            )
        }

        let legacyAverage = average(legacySamples)
        let displayedBackdropAverageAverage = average(displayedBackdropAverageSamples)
        let displayedBackdropReadabilityAverage = average(displayedBackdropReadabilitySamples)
        let legacyP95 = p95(legacySamples)
        let displayedBackdropAverageP95 = p95(displayedBackdropAverageSamples)
        let displayedBackdropReadabilityP95 = p95(displayedBackdropReadabilitySamples)

        let deltaAverageVsDisplayedBackdropAverage =
            displayedBackdropReadabilityAverage - displayedBackdropAverageAverage
        let deltaP95VsDisplayedBackdropAverage =
            displayedBackdropReadabilityP95 - displayedBackdropAverageP95
        let deltaPercentVsDisplayedBackdropAverage =
            displayedBackdropAverageAverage > 0
            ? ((deltaAverageVsDisplayedBackdropAverage / displayedBackdropAverageAverage) * 100)
            : 0

        print("[perf] EXIF legacy samples (ms) = [\(formatSamples(legacySamples))]")
        print("[perf] EXIF screen mean luma samples (ms) = [\(formatSamples(displayedBackdropAverageSamples))]")
        print("[perf] EXIF white-first luma samples (ms) = [\(formatSamples(displayedBackdropReadabilitySamples))]")
        print("[perf] EXIF legacy avg (ms) = \(String(format: "%.2f", legacyAverage))")
        print("[perf] EXIF screen mean luma avg (ms) = \(String(format: "%.2f", displayedBackdropAverageAverage))")
        print("[perf] EXIF white-first luma avg (ms) = \(String(format: "%.2f", displayedBackdropReadabilityAverage))")
        print("[perf] EXIF legacy P95 (ms) = \(String(format: "%.2f", legacyP95))")
        print("[perf] EXIF screen mean luma P95 (ms) = \(String(format: "%.2f", displayedBackdropAverageP95))")
        print("[perf] EXIF white-first luma P95 (ms) = \(String(format: "%.2f", displayedBackdropReadabilityP95))")
        print("[perf] EXIF avg delta vs prev (ms) = \(String(format: "%.2f", deltaAverageVsDisplayedBackdropAverage))")
        print("[perf] EXIF P95 delta vs prev (ms) = \(String(format: "%.2f", deltaP95VsDisplayedBackdropAverage))")
        print("[perf] EXIF avg growth vs prev (%) = \(String(format: "%.1f", deltaPercentVsDisplayedBackdropAverage))")

        // Only assert that both algorithms ran; no hard-coded millisecond thresholds.

        #expect(legacyAverage > 0)
        #expect(displayedBackdropAverageAverage > 0)
        #expect(displayedBackdropReadabilityAverage > 0)
    }
}

#endif
