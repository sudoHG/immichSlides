import Foundation

/// Photo coverage shared by App lifecycle tests and public fixture captures.
enum SceneTransitionDiagnostic {
    /// Share of the screen that photo layers must cover in every sample; below it the screen reads as empty.
    static let minimumPhotoCoverage = 0.5
    static let firstVisibleTickOffsetSeconds = TestWait.seconds(.product(0.5))

    /// Share of the screen covered when the layers are composited over the black backing.
    static func photoCoverage(of opacities: [Double]) -> Double {
        1 - opacities.reduce(1) { uncovered, opacity in uncovered * (1 - opacity) }
    }
}
