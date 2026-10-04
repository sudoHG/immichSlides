//
//  PlaybackSmartFillLayoutPolicy.swift
//  immichSlides
//

import Foundation

struct PlaybackSmartFillLayoutPolicy: Equatable, Sendable {
    let layoutPolicyId: String
    let sceneSearchOrder: [PlaybackSmartFillSceneType]
    let layoutAllowlist: [PlaybackSmartFillLayoutVariant]
    let ratioPresetsByVariant: [PlaybackSmartFillLayoutVariant: [PlaybackSmartFillRatioPreset]]
    let candidateWindowPresets: [Int]
    let allowsSingleCandidateLookahead: Bool
    let allowsCurrentCandidateAsAuxiliaryLookahead: Bool
    let slotAspectRatioRange: PlaybackSmartFillAspectRatioRange
    let cropRetentionThreshold: Double
    let upperBodyProxyParams: PlaybackSmartFillUpperBodyProxyParams
    let minimumSecondaryArea: Double
    let minimumEffectivePixelScale: Double
    // Constructive doubles are sorted by ideal geometric ratio first; top-K only limits search breadth and does not
    // change evaluate's acceptance criteria.
    let constructiveDoublePartnerSearchLimit: Int
    // Combinations grow quickly in failing multi-slot scenes; the candidate pool cap bounds the worst-case pure
    // search cost.
    let multiSlotCandidatePoolLimit: Int
    // The total evaluate budget per plan bounds search on inputs that fit no layout.
    let evaluationBudget: Int
    // current-as-auxiliary is a required path for iPad/Apple TV triples; it needs a reserved budget so the
    // current-primary search cannot starve it.
    let currentAuxiliaryEvaluationReserve: Int
    let verticalDoubleFrames: PlaybackSmartFillDoubleFrames?
    let horizontalDoubleFrames: PlaybackSmartFillDoubleFrames?
    let tripleFrames: PlaybackSmartFillTripleFrames?

    nonisolated var surfacePolicyId: String { layoutPolicyId }

    nonisolated var allowsVerticalDouble: Bool {
        layoutAllowlist.contains(.verticalEqual) || layoutAllowlist.contains(.topPrimaryBottomSecondary)
            || layoutAllowlist.contains(.bottomPrimaryTopSecondary)
    }

    nonisolated var allowsHorizontalDouble: Bool {
        layoutAllowlist.contains(.horizontalEqual) || layoutAllowlist.contains(.leftPrimaryRightSecondary)
            || layoutAllowlist.contains(.rightPrimaryLeftSecondary)
    }

    nonisolated var allowsTriple: Bool {
        layoutAllowlist.contains(where: { $0.isTriple })
    }

    nonisolated func ratioPresets(for variant: PlaybackSmartFillLayoutVariant) -> [PlaybackSmartFillRatioPreset] {
        ratioPresetsByVariant[variant] ?? []
    }

    nonisolated static func policy(for surface: PlaybackSmartFillSurface) -> PlaybackSmartFillLayoutPolicy {
        switch (surface.profile, surface.orientation) {
        case (.iPhone, .portrait):
            return PlaybackSmartFillLayoutPolicy(
                layoutPolicyId: "iphone-portrait-pr49-v1",
                sceneSearchOrder: [.single, .double, .fallback],
                layoutAllowlist: [
                    .verticalEqual,
                    .topPrimaryBottomSecondary,
                    .bottomPrimaryTopSecondary
                ],
                ratioPresetsByVariant: [
                    .verticalEqual: [ratio("50/50", 0.50)],
                    .topPrimaryBottomSecondary: [
                        ratio("28/72", 0.28), ratio("45/55", 0.45), ratio("40/60", 0.40), ratio("60/40", 0.60),
                        ratio("65/35", 0.65), ratio("70/30", 0.70)
                    ],
                    .bottomPrimaryTopSecondary: [
                        ratio("45/55", 0.45), ratio("40/60", 0.40), ratio("60/40", 0.60), ratio("65/35", 0.65),
                        ratio("70/30", 0.70), ratio("72/28", 0.72)
                    ]
                ],
                allowsCurrentCandidateAsAuxiliaryLookahead: true,
                cropRetentionThreshold: 0.60,
                minimumSecondaryArea: 0.28,
                minimumEffectivePixelScale: 0.85
            )
        case (.iPhone, .landscape):
            return PlaybackSmartFillLayoutPolicy(
                layoutPolicyId: "iphone-landscape-pr49-v1",
                sceneSearchOrder: [.single, .double, .fallback],
                layoutAllowlist: [
                    .horizontalEqual,
                    .leftPrimaryRightSecondary,
                    .rightPrimaryLeftSecondary
                ],
                ratioPresetsByVariant: [
                    .horizontalEqual: [ratio("50/50", 0.50)],
                    .leftPrimaryRightSecondary: [
                        ratio("28/72", 0.28), ratio("45/55", 0.45), ratio("55/45", 0.55), ratio("40/60", 0.40),
                        ratio("60/40", 0.60), ratio("65/35", 0.65), ratio("72/28", 0.72)
                    ],
                    .rightPrimaryLeftSecondary: [
                        ratio("28/72", 0.28), ratio("45/55", 0.45), ratio("55/45", 0.55), ratio("40/60", 0.40),
                        ratio("60/40", 0.60), ratio("65/35", 0.65), ratio("72/28", 0.72)
                    ]
                ],
                allowsCurrentCandidateAsAuxiliaryLookahead: true,
                cropRetentionThreshold: 0.60,
                minimumSecondaryArea: 0.28,
                minimumEffectivePixelScale: 0.85
            )
        case (.iPad, .portrait):
            return PlaybackSmartFillLayoutPolicy(
                layoutPolicyId: "ipad-portrait-pr49-v1",
                sceneSearchOrder: [.single, .double, .triple, .fallback],
                layoutAllowlist: [
                    .verticalEqual,
                    .topPrimaryBottomSecondary,
                    .bottomPrimaryTopSecondary,
                    .topPrimaryBottomPair,
                    .bottomPrimaryTopPair
                ],
                ratioPresetsByVariant: [
                    .verticalEqual: [ratio("50/50", 0.50)],
                    .topPrimaryBottomSecondary: [ratio("60/40", 0.60), ratio("65/35", 0.65), ratio("70/30", 0.70)],
                    .bottomPrimaryTopSecondary: [ratio("60/40", 0.60), ratio("65/35", 0.65), ratio("70/30", 0.70)],
                    .topPrimaryBottomPair: [ratio("56/44", 0.56), ratio("60/40", 0.60), ratio("64/36", 0.64)],
                    .bottomPrimaryTopPair: [ratio("56/44", 0.56), ratio("60/40", 0.60), ratio("64/36", 0.64)]
                ],
                allowsCurrentCandidateAsAuxiliaryLookahead: true,
                minimumSecondaryArea: 0.18,
                minimumEffectivePixelScale: 0.85
            )
        case (.iPad, .landscape):
            return PlaybackSmartFillLayoutPolicy(
                layoutPolicyId: "ipad-landscape-pr49-v1",
                sceneSearchOrder: [.single, .double, .triple, .fallback],
                layoutAllowlist: [
                    .horizontalEqual,
                    .leftPrimaryRightSecondary,
                    .rightPrimaryLeftSecondary,
                    .leftPrimaryRightStack,
                    .rightPrimaryLeftStack,
                    .topPrimaryBottomPair,
                    .bottomPrimaryTopPair,
                    .balancedGrid
                ],
                ratioPresetsByVariant: [
                    .horizontalEqual: [ratio("50/50", 0.50)],
                    .leftPrimaryRightSecondary: [
                        ratio("55/45", 0.55), ratio("60/40", 0.60), ratio("65/35", 0.65), ratio("80/20", 0.80)
                    ],
                    .rightPrimaryLeftSecondary: [
                        ratio("55/45", 0.55), ratio("60/40", 0.60), ratio("65/35", 0.65), ratio("80/20", 0.80)
                    ],
                    .leftPrimaryRightStack: [ratio("56/44", 0.56), ratio("60/40", 0.60), ratio("64/36", 0.64)],
                    .rightPrimaryLeftStack: [ratio("56/44", 0.56), ratio("60/40", 0.60), ratio("64/36", 0.64)],
                    .topPrimaryBottomPair: [ratio("56/44", 0.56), ratio("60/40", 0.60), ratio("64/36", 0.64)],
                    .bottomPrimaryTopPair: [ratio("56/44", 0.56), ratio("60/40", 0.60), ratio("64/36", 0.64)],
                    .balancedGrid: [ratio("equal-thirds", 1.0 / 3.0)]
                ],
                allowsCurrentCandidateAsAuxiliaryLookahead: true,
                minimumSecondaryArea: 0.18,
                minimumEffectivePixelScale: 0.85
            )
        case (.appleTV, _):
            return PlaybackSmartFillLayoutPolicy(
                layoutPolicyId: "appletv-landscape-pr49-v1",
                sceneSearchOrder: [.single, .double, .triple, .fallback],
                layoutAllowlist: [
                    .horizontalEqual,
                    .leftPrimaryRightSecondary,
                    .rightPrimaryLeftSecondary,
                    .leftPrimaryRightStack,
                    .rightPrimaryLeftStack,
                    .topPrimaryBottomPair,
                    .bottomPrimaryTopPair,
                    .balancedGrid
                ],
                ratioPresetsByVariant: [
                    .horizontalEqual: [ratio("50/50", 0.50)],
                    .leftPrimaryRightSecondary: [
                        ratio("55/45", 0.55), ratio("60/40", 0.60), ratio("65/35", 0.65), ratio("80/20", 0.80)
                    ],
                    .rightPrimaryLeftSecondary: [
                        ratio("55/45", 0.55), ratio("60/40", 0.60), ratio("65/35", 0.65), ratio("80/20", 0.80)
                    ],
                    .leftPrimaryRightStack: [ratio("56/44", 0.56), ratio("60/40", 0.60), ratio("64/36", 0.64)],
                    .rightPrimaryLeftStack: [ratio("56/44", 0.56), ratio("60/40", 0.60), ratio("64/36", 0.64)],
                    .topPrimaryBottomPair: [ratio("56/44", 0.56), ratio("60/40", 0.60), ratio("64/36", 0.64)],
                    .bottomPrimaryTopPair: [ratio("56/44", 0.56), ratio("60/40", 0.60), ratio("64/36", 0.64)],
                    .balancedGrid: [ratio("equal-thirds", 1.0 / 3.0)]
                ],
                allowsCurrentCandidateAsAuxiliaryLookahead: true,
                minimumSecondaryArea: 0.20,
                minimumEffectivePixelScale: 0.85
            )
        }
    }

    private nonisolated init(
        layoutPolicyId: String,
        sceneSearchOrder: [PlaybackSmartFillSceneType],
        layoutAllowlist: [PlaybackSmartFillLayoutVariant],
        ratioPresetsByVariant: [PlaybackSmartFillLayoutVariant: [PlaybackSmartFillRatioPreset]],
        allowsSingleCandidateLookahead: Bool = false,
        allowsCurrentCandidateAsAuxiliaryLookahead: Bool = false,
        cropRetentionThreshold: Double = 0.60,
        minimumSecondaryArea: Double,
        minimumEffectivePixelScale: Double,
        constructiveDoublePartnerSearchLimit: Int = 12,
        multiSlotCandidatePoolLimit: Int = 72,
        evaluationBudget: Int = 4_000,
        currentAuxiliaryEvaluationReserve: Int = 2_000
    ) {
        self.layoutPolicyId = layoutPolicyId
        self.sceneSearchOrder = sceneSearchOrder
        self.layoutAllowlist = layoutAllowlist
        self.ratioPresetsByVariant = ratioPresetsByVariant
        self.candidateWindowPresets = [24, 48, 72]
        self.allowsSingleCandidateLookahead = allowsSingleCandidateLookahead
        self.allowsCurrentCandidateAsAuxiliaryLookahead = allowsCurrentCandidateAsAuxiliaryLookahead
        self.slotAspectRatioRange = .commonPhotoExtreme
        self.cropRetentionThreshold = cropRetentionThreshold
        self.upperBodyProxyParams = .defaultSpec
        self.minimumSecondaryArea = minimumSecondaryArea
        self.minimumEffectivePixelScale = minimumEffectivePixelScale
        self.constructiveDoublePartnerSearchLimit = constructiveDoublePartnerSearchLimit
        self.multiSlotCandidatePoolLimit = multiSlotCandidatePoolLimit
        self.evaluationBudget = evaluationBudget
        self.currentAuxiliaryEvaluationReserve = currentAuxiliaryEvaluationReserve
        self.verticalDoubleFrames = Self.firstDoubleFrames(
            from: layoutAllowlist,
            ratioPresetsByVariant: ratioPresetsByVariant,
            variants: [.verticalEqual, .topPrimaryBottomSecondary, .bottomPrimaryTopSecondary]
        )
        self.horizontalDoubleFrames = Self.firstDoubleFrames(
            from: layoutAllowlist,
            ratioPresetsByVariant: ratioPresetsByVariant,
            variants: [.horizontalEqual, .leftPrimaryRightSecondary, .rightPrimaryLeftSecondary]
        )
        self.tripleFrames = Self.firstTripleFrames(
            from: layoutAllowlist,
            ratioPresetsByVariant: ratioPresetsByVariant
        )
    }

    private nonisolated static func ratio(_ id: String, _ primaryShare: Double) -> PlaybackSmartFillRatioPreset {
        PlaybackSmartFillRatioPreset(id: id, primaryShare: primaryShare)
    }

    private nonisolated static func firstDoubleFrames(
        from allowlist: [PlaybackSmartFillLayoutVariant],
        ratioPresetsByVariant: [PlaybackSmartFillLayoutVariant: [PlaybackSmartFillRatioPreset]],
        variants: [PlaybackSmartFillLayoutVariant]
    ) -> PlaybackSmartFillDoubleFrames? {
        for variant in variants where allowlist.contains(variant) {
            guard let preset = ratioPresetsByVariant[variant]?.first else { continue }
            let frames = PlaybackSmartFillLayoutCatalog.frames(for: variant, preset: preset)
            guard frames.count == 2 else { continue }
            return PlaybackSmartFillDoubleFrames(primary: frames[0], secondary: frames[1])
        }
        return nil
    }

    private nonisolated static func firstTripleFrames(
        from allowlist: [PlaybackSmartFillLayoutVariant],
        ratioPresetsByVariant: [PlaybackSmartFillLayoutVariant: [PlaybackSmartFillRatioPreset]]
    ) -> PlaybackSmartFillTripleFrames? {
        for variant in allowlist where variant.isTriple {
            guard let preset = ratioPresetsByVariant[variant]?.first else { continue }
            let frames = PlaybackSmartFillLayoutCatalog.frames(for: variant, preset: preset)
            guard frames.count == 3 else { continue }
            return PlaybackSmartFillTripleFrames(primary: frames[0], secondary: frames[1], tertiary: frames[2])
        }
        return nil
    }
}

struct PlaybackSmartFillPointSize: Equatable, Sendable {
    let width: Double
    let height: Double
}

struct PlaybackSmartFillPhotoCanvasDescriptor: Equatable, Sendable {
    let profile: PlaybackSmartFillSurfaceProfile
    let orientation: PlaybackSmartFillOrientation
    let surfaceFingerprint: String
    let pointSize: PlaybackSmartFillPointSize
    let pixelSize: PlaybackPlanningPixelSize
    let safeAreaClass: String
    let hardSystemObstructionClass: String
    let renderScale: Double
    let unitCanvas: PlaybackPlanningRect
    let canvasId: String

    nonisolated init(
        surface: PlaybackSmartFillSurface,
        pointSize: PlaybackSmartFillPointSize? = nil,
        renderScale: Double = 1,
        hardSystemObstructionClass: String = "none",
        unitCanvas: PlaybackPlanningRect = .fullUnitRect,
        canvasId: String? = nil
    ) {
        let normalizedRenderScale = Self.normalizedRenderScale(renderScale)
        let resolvedPointSize =
            pointSize
            ?? PlaybackSmartFillPointSize(
                width: Double(surface.pixelSize.width) / normalizedRenderScale,
                height: Double(surface.pixelSize.height) / normalizedRenderScale
            )

        self.profile = surface.profile
        self.orientation = surface.orientation
        self.surfaceFingerprint = surface.internalSurfaceFingerprint
        self.pointSize = resolvedPointSize
        self.pixelSize = surface.pixelSize
        self.safeAreaClass = surface.safeAreaClass
        self.hardSystemObstructionClass = hardSystemObstructionClass
        self.renderScale = normalizedRenderScale
        self.unitCanvas = unitCanvas
        self.canvasId =
            canvasId
            ?? Self.defaultCanvasId(
                surface: surface,
                pointSize: resolvedPointSize,
                renderScale: normalizedRenderScale,
                hardSystemObstructionClass: hardSystemObstructionClass,
                unitCanvas: unitCanvas
            )
    }

    nonisolated init(pixelSize: PlaybackPlanningPixelSize) {
        self.profile = .iPad
        self.orientation = pixelSize.width >= pixelSize.height ? .landscape : .portrait
        self.surfaceFingerprint = "pixel-only:\(pixelSize.width)x\(pixelSize.height)"
        self.pointSize = PlaybackSmartFillPointSize(width: Double(pixelSize.width), height: Double(pixelSize.height))
        self.pixelSize = pixelSize
        self.safeAreaClass = "unknown"
        self.hardSystemObstructionClass = "none"
        self.renderScale = 1
        self.unitCanvas = .fullUnitRect
        self.canvasId = "pixel-only:\(pixelSize.width)x\(pixelSize.height)"
    }

    private nonisolated static func normalizedRenderScale(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }

    private nonisolated static func defaultCanvasId(
        surface: PlaybackSmartFillSurface,
        pointSize: PlaybackSmartFillPointSize,
        renderScale: Double,
        hardSystemObstructionClass: String,
        unitCanvas: PlaybackPlanningRect
    ) -> String {
        [
            "surface:\(surface.internalSurfaceFingerprint)",
            "safeArea:\(surface.safeAreaClass)",
            "hardObstruction:\(hardSystemObstructionClass)",
            "px:\(surface.pixelSize.width)x\(surface.pixelSize.height)",
            "pt:\(format(pointSize.width))x\(format(pointSize.height))",
            "scale:\(format(renderScale))",
            "unit:\(format(unitCanvas.x)),\(format(unitCanvas.y)),\(format(unitCanvas.width)),\(format(unitCanvas.height))"
        ].joined(separator: "|")
    }

    private nonisolated static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

extension PlaybackSmartFillLayoutVariant: CaseIterable {
    nonisolated static var allCases: [PlaybackSmartFillLayoutVariant] {
        [
            .single,
            .verticalEqual,
            .horizontalEqual,
            .topPrimaryBottomSecondary,
            .bottomPrimaryTopSecondary,
            .leftPrimaryRightSecondary,
            .rightPrimaryLeftSecondary,
            .leftPrimaryRightStack,
            .rightPrimaryLeftStack,
            .topPrimaryBottomPair,
            .bottomPrimaryTopPair,
            .balancedGrid
        ]
    }
}

enum PlaybackSmartFillLayoutCatalog {
    nonisolated static func frames(
        for variant: PlaybackSmartFillLayoutVariant,
        preset: PlaybackSmartFillRatioPreset
    ) -> [PlaybackPlanningRect] {
        let primary = preset.primaryShare
        switch variant {
        case .single:
            return [.fullUnitRect]
        case .verticalEqual, .topPrimaryBottomSecondary:
            return [
                PlaybackPlanningRect(x: 0, y: 0, width: 1, height: primary),
                PlaybackPlanningRect(x: 0, y: primary, width: 1, height: 1 - primary)
            ]
        case .bottomPrimaryTopSecondary:
            return [
                PlaybackPlanningRect(x: 0, y: 1 - primary, width: 1, height: primary),
                PlaybackPlanningRect(x: 0, y: 0, width: 1, height: 1 - primary)
            ]
        case .horizontalEqual, .leftPrimaryRightSecondary:
            return [
                PlaybackPlanningRect(x: 0, y: 0, width: primary, height: 1),
                PlaybackPlanningRect(x: primary, y: 0, width: 1 - primary, height: 1)
            ]
        case .rightPrimaryLeftSecondary:
            return [
                PlaybackPlanningRect(x: 1 - primary, y: 0, width: primary, height: 1),
                PlaybackPlanningRect(x: 0, y: 0, width: 1 - primary, height: 1)
            ]
        case .leftPrimaryRightStack:
            return [
                PlaybackPlanningRect(x: 0, y: 0, width: primary, height: 1),
                PlaybackPlanningRect(x: primary, y: 0, width: 1 - primary, height: 0.5),
                PlaybackPlanningRect(x: primary, y: 0.5, width: 1 - primary, height: 0.5)
            ]
        case .rightPrimaryLeftStack:
            return [
                PlaybackPlanningRect(x: 1 - primary, y: 0, width: primary, height: 1),
                PlaybackPlanningRect(x: 0, y: 0, width: 1 - primary, height: 0.5),
                PlaybackPlanningRect(x: 0, y: 0.5, width: 1 - primary, height: 0.5)
            ]
        case .topPrimaryBottomPair:
            return [
                PlaybackPlanningRect(x: 0, y: 0, width: 1, height: primary),
                PlaybackPlanningRect(x: 0, y: primary, width: 0.5, height: 1 - primary),
                PlaybackPlanningRect(x: 0.5, y: primary, width: 0.5, height: 1 - primary)
            ]
        case .bottomPrimaryTopPair:
            return [
                PlaybackPlanningRect(x: 0, y: 1 - primary, width: 1, height: primary),
                PlaybackPlanningRect(x: 0, y: 0, width: 0.5, height: 1 - primary),
                PlaybackPlanningRect(x: 0.5, y: 0, width: 0.5, height: 1 - primary)
            ]
        case .balancedGrid:
            return [
                PlaybackPlanningRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1),
                PlaybackPlanningRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1),
                PlaybackPlanningRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
            ]
        }
    }
}

struct PlaybackSmartFillLayoutGeometrySummary: Equatable, Sendable {
    let isFullCanvas: Bool
    let coverageRatio: Double
    let emptyCanvasRatio: Double
    let gapPixelCount: Int
    let overlapUnitArea: Double
    let overlapPixelCount: Int
    let outOfBoundsUnitArea: Double
    let outOfBoundsPixelCount: Int
    let maxContinuousEmptyAxisRatio: Double

    var debugSummary: String {
        [
            "fullCanvas=\(isFullCanvas)",
            "coverage=\(format(coverageRatio))",
            "empty=\(format(emptyCanvasRatio))",
            "gapPixels=\(gapPixelCount)",
            "overlapUnit=\(format(overlapUnitArea))",
            "overlapPixels=\(overlapPixelCount)",
            "outOfBoundsUnit=\(format(outOfBoundsUnitArea))",
            "outOfBoundsPixels=\(outOfBoundsPixelCount)",
            "maxEmptyAxis=\(format(maxContinuousEmptyAxisRatio))"
        ].joined(separator: ",")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.10f", value)
    }
}

enum PlaybackSmartFillLayoutGeometryInvariant {
    private nonisolated static let epsilon = 1e-9

    nonisolated static func evaluate(
        frames: [PlaybackPlanningRect],
        photoCanvas: PlaybackSmartFillPhotoCanvasDescriptor
    ) -> PlaybackSmartFillLayoutGeometrySummary {
        let pixelWidth = max(1, photoCanvas.pixelSize.width)
        let pixelHeight = max(1, photoCanvas.pixelSize.height)
        let totalPixels = pixelWidth * pixelHeight
        guard !frames.isEmpty else {
            return PlaybackSmartFillLayoutGeometrySummary(
                isFullCanvas: false,
                coverageRatio: 0,
                emptyCanvasRatio: 1,
                gapPixelCount: totalPixels,
                overlapUnitArea: 0,
                overlapPixelCount: 0,
                outOfBoundsUnitArea: 0,
                outOfBoundsPixelCount: 0,
                maxContinuousEmptyAxisRatio: 1
            )
        }

        let clampedFrames = frames.map(clamped)
        let overlapUnitArea = overlapUnitArea(frames: clampedFrames)
        let xEdges = unitEdges(from: clampedFrames.flatMap { [$0.x, $0.x + $0.width] })
        let yEdges = unitEdges(from: clampedFrames.flatMap { [$0.y, $0.y + $0.height] })
        let xIntervals = adjacentIntervals(xEdges)
        let yIntervals = adjacentIntervals(yEdges)
        var occupiedArea = 0.0
        var gapPixels = 0
        var overlapPixels = 0
        var occupancy = Array(
            repeating: Array(repeating: 0, count: yIntervals.count),
            count: xIntervals.count
        )

        for xIndex in xIntervals.indices {
            let xInterval = xIntervals[xIndex]
            for yIndex in yIntervals.indices {
                let yInterval = yIntervals[yIndex]
                let count = clampedFrames.filter {
                    covers(xInterval: xInterval, yInterval: yInterval, by: $0)
                }.count
                occupancy[xIndex][yIndex] = count
                let unitArea = (xInterval.upper - xInterval.lower) * (yInterval.upper - yInterval.lower)
                let pixels = pixelArea(
                    xInterval: xInterval,
                    yInterval: yInterval,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight
                )

                if count == 0 {
                    gapPixels += pixels
                } else {
                    occupiedArea += unitArea
                    if count > 1 {
                        overlapPixels += pixels
                    }
                }
            }
        }

        let outOfBoundsUnitArea = outOfBoundsUnitArea(frames: frames)
        let outOfBoundsPixels = pixelCount(
            unitArea: outOfBoundsUnitArea,
            totalPixels: totalPixels
        )
        let emptyRatio = max(0, 1 - occupiedArea)
        let maxEmptyAxisRatio = maxContinuousEmptyAxisRatio(
            occupancy: occupancy,
            xIntervals: xIntervals,
            yIntervals: yIntervals
        )
        let fullCanvas =
            gapPixels == 0
            && overlapPixels == 0
            && outOfBoundsPixels == 0
            && overlapUnitArea <= epsilon
            && outOfBoundsUnitArea <= epsilon
            && occupiedArea >= 1 - epsilon
            && emptyRatio <= epsilon
            && maxEmptyAxisRatio <= epsilon

        return PlaybackSmartFillLayoutGeometrySummary(
            isFullCanvas: fullCanvas,
            coverageRatio: min(1, occupiedArea),
            emptyCanvasRatio: emptyRatio,
            gapPixelCount: gapPixels,
            overlapUnitArea: overlapUnitArea,
            overlapPixelCount: overlapPixels,
            outOfBoundsUnitArea: outOfBoundsUnitArea,
            outOfBoundsPixelCount: outOfBoundsPixels,
            maxContinuousEmptyAxisRatio: maxEmptyAxisRatio
        )
    }

    private nonisolated static func unitEdges(from values: [Double]) -> [Double] {
        let clampedValues = values.map { max(0, min(1, $0)) }
        let allValues = ([0.0, 1.0] + clampedValues).filter { $0.isFinite }
        return Array(Set(allValues.map { rounded($0) })).sorted()
    }

    private nonisolated static func rounded(_ value: Double) -> Double {
        (value * 1_000_000_000).rounded() / 1_000_000_000
    }

    private nonisolated static func adjacentIntervals(_ edges: [Double]) -> [(lower: Double, upper: Double)] {
        guard edges.count > 1 else { return [] }
        return zip(edges.dropLast(), edges.dropFirst())
            .filter { pair in pair.0 < pair.1 }
            .map { pair in (lower: pair.0, upper: pair.1) }
    }

    private nonisolated static func covers(
        xInterval: (lower: Double, upper: Double),
        yInterval: (lower: Double, upper: Double),
        by frame: PlaybackPlanningRect
    ) -> Bool {
        frame.width > 0
            && frame.height > 0
            && frame.x <= xInterval.lower + epsilon
            && frame.x + frame.width >= xInterval.upper - epsilon
            && frame.y <= yInterval.lower + epsilon
            && frame.y + frame.height >= yInterval.upper - epsilon
    }

    private nonisolated static func pixelArea(
        xInterval: (lower: Double, upper: Double),
        yInterval: (lower: Double, upper: Double),
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Int {
        let left = pixelCoordinate(xInterval.lower, scale: pixelWidth)
        let right = pixelCoordinate(xInterval.upper, scale: pixelWidth)
        let top = pixelCoordinate(yInterval.lower, scale: pixelHeight)
        let bottom = pixelCoordinate(yInterval.upper, scale: pixelHeight)
        return max(0, right - left) * max(0, bottom - top)
    }

    private nonisolated static func pixelCoordinate(_ value: Double, scale: Int) -> Int {
        Int((max(0, min(1, value)) * Double(scale)).rounded())
    }

    private nonisolated static func overlapUnitArea(frames: [PlaybackPlanningRect]) -> Double {
        var overlapArea = 0.0
        for firstIndex in frames.indices {
            let first = frames[firstIndex]
            for secondIndex in frames.indices.dropFirst(firstIndex + 1) {
                let second = frames[secondIndex]
                let intersectionWidth = min(first.x + first.width, second.x + second.width) - max(first.x, second.x)
                let intersectionHeight = min(first.y + first.height, second.y + second.height) - max(first.y, second.y)
                if intersectionWidth > 0 && intersectionHeight > 0 {
                    overlapArea += intersectionWidth * intersectionHeight
                }
            }
        }
        return overlapArea
    }

    private nonisolated static func outOfBoundsUnitArea(
        frames: [PlaybackPlanningRect],
    ) -> Double {
        frames.reduce(0.0) { partial, frame in
            let frameArea = max(0, frame.width) * max(0, frame.height)
            let clampedFrame = clamped(frame)
            let clampedArea = clampedFrame.width * clampedFrame.height
            return partial + max(0, frameArea - clampedArea)
        }
    }

    private nonisolated static func pixelCount(
        unitArea: Double,
        totalPixels: Int
    ) -> Int {
        Int((unitArea * Double(totalPixels)).rounded())
    }

    private nonisolated static func maxContinuousEmptyAxisRatio(
        occupancy: [[Int]],
        xIntervals: [(lower: Double, upper: Double)],
        yIntervals: [(lower: Double, upper: Double)]
    ) -> Double {
        let verticalGap = maxContinuousEmptyRun(
            lengths: xIntervals.map { $0.upper - $0.lower },
            emptyFlags: occupancy.map { column in
                column.allSatisfy { $0 == 0 }
            }
        )
        let horizontalGap = maxContinuousEmptyRun(
            lengths: yIntervals.map { $0.upper - $0.lower },
            emptyFlags: yIntervals.indices.map { yIndex in
                occupancy.indices.allSatisfy { xIndex in
                    occupancy[xIndex][yIndex] == 0
                }
            }
        )
        return max(verticalGap, horizontalGap)
    }

    private nonisolated static func maxContinuousEmptyRun(
        lengths: [Double],
        emptyFlags: [Bool]
    ) -> Double {
        var current = 0.0
        var maximum = 0.0
        for (length, isEmpty) in zip(lengths, emptyFlags) {
            if isEmpty {
                current += length
                maximum = max(maximum, current)
            } else {
                current = 0
            }
        }
        return maximum
    }

    private nonisolated static func clamped(_ rect: PlaybackPlanningRect) -> PlaybackPlanningRect {
        let x = max(0, min(1, rect.x))
        let y = max(0, min(1, rect.y))
        let maxX = max(0, min(1, rect.x + rect.width))
        let maxY = max(0, min(1, rect.y + rect.height))
        return PlaybackPlanningRect(
            x: x,
            y: y,
            width: max(0, maxX - x),
            height: max(0, maxY - y)
        )
    }
}

struct PlaybackSmartFillDoubleFrames: Equatable, Sendable {
    let primary: PlaybackPlanningRect
    let secondary: PlaybackPlanningRect
}

struct PlaybackSmartFillTripleFrames: Equatable, Sendable {
    let primary: PlaybackPlanningRect
    let secondary: PlaybackPlanningRect
    let tertiary: PlaybackPlanningRect
}
