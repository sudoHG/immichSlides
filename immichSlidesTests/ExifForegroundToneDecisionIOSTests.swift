import Foundation
import Testing
import UIKit
@testable import immichSlides

#if os(iOS)

@Suite
@MainActor
struct ExifForegroundToneDecisionIOSTests {

    private func makeToneDecisionImage(
        topColor: UIColor,
        bottomColor: UIColor
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3024, height: 4032))
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setFillColor(topColor.cgColor)
            cgContext.fill(CGRect(x: 0, y: 0, width: 3024, height: 1200))
            cgContext.setFillColor(bottomColor.cgColor)
            cgContext.fill(CGRect(x: 0, y: 1200, width: 3024, height: 2832))
        }
    }

    @Test
    func `white-text-preferred rule stays stable across typical light and midtone backdrops`() throws {
        let backdropContext = ExifDisplayedBackdropContext(
            surfaceSize: CGSize(width: 393, height: 852),
            safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
            exifFrameInSurfaceSpace: CGRect(x: 228, y: 74, width: 150, height: 78)
        )

        let paleSkyImage = makeToneDecisionImage(
            topColor: UIColor(red: 0.90, green: 0.93, blue: 0.98, alpha: 1),
            bottomColor: UIColor(red: 0.42, green: 0.36, blue: 0.34, alpha: 1)
        )
        let greenMidtoneImage = makeToneDecisionImage(
            topColor: UIColor(red: 0.52, green: 0.59, blue: 0.44, alpha: 1),
            bottomColor: UIColor(red: 0.26, green: 0.34, blue: 0.18, alpha: 1)
        )
        let warmBrownImage = makeToneDecisionImage(
            topColor: UIColor(red: 0.63, green: 0.58, blue: 0.49, alpha: 1),
            bottomColor: UIColor(red: 0.30, green: 0.23, blue: 0.20, alpha: 1)
        )

        let paleSkyCGImage = try #require(paleSkyImage.cgImage)
        let greenMidtoneCGImage = try #require(greenMidtoneImage.cgImage)
        let warmBrownCGImage = try #require(warmBrownImage.cgImage)

        let paleSkyTone = try #require(
            ExifForegroundAnalyzer.displayedBackdropToneForBenchmark(
                from: paleSkyCGImage,
                backdropContext: backdropContext
            )
        )
        let greenMidtoneTone = try #require(
            ExifForegroundAnalyzer.displayedBackdropToneForBenchmark(
                from: greenMidtoneCGImage,
                backdropContext: backdropContext
            )
        )
        let warmBrownTone = try #require(
            ExifForegroundAnalyzer.displayedBackdropToneForBenchmark(
                from: warmBrownCGImage,
                backdropContext: backdropContext
            )
        )

        #expect(paleSkyTone == .darkText)
        #expect(greenMidtoneTone == .lightText)
        #expect(warmBrownTone == .lightText)
    }
}

#endif
