//
//  FaceBoxGeometry.swift
//  immichSlides
//
//  Immich face box coordinate validation only produces geometric facts; it makes no cropping, playback or UI
//  decisions.
//

import CoreGraphics
import Foundation

enum FaceBoxGeometry {

    enum DimensionRelation: String, Equatable {
        case match
        case rotatedPair
        case mismatch
        case insufficientData
    }

    enum UnusableReason: String, Equatable {
        case missingCoordinates
        case invalidImageDimensions
        case invalidCoordinateOrder
        case outOfBounds
    }

    enum ValidationResult: Equatable {
        case usable(normalizedRect: CGRect, dimensionRelation: DimensionRelation)
        case unusable(reason: UnusableReason, dimensionRelation: DimensionRelation)

        var isUsable: Bool {
            if case .usable = self { return true }
            return false
        }
    }

    static func collectFaces(from people: [People]?) -> [FaceBox] {
        people?.flatMap { $0.faces ?? [] } ?? []
    }

    static func validate(faces: [FaceBox], asset: Asset) -> [ValidationResult] {
        faces.map { validate(face: $0, asset: asset) }
    }

    static func validate(face: FaceBox, asset: Asset) -> ValidationResult {
        let relation = dimensionRelation(face: face, asset: asset)

        guard let imageWidth = face.imageWidth, let imageHeight = face.imageHeight,
            imageWidth > 0, imageHeight > 0
        else {
            return .unusable(reason: .invalidImageDimensions, dimensionRelation: .insufficientData)
        }

        guard let x1 = face.boundingBoxX1, let x2 = face.boundingBoxX2,
            let y1 = face.boundingBoxY1, let y2 = face.boundingBoxY2
        else {
            return .unusable(reason: .missingCoordinates, dimensionRelation: relation)
        }

        guard x1 < x2, y1 < y2 else {
            return .unusable(reason: .invalidCoordinateOrder, dimensionRelation: relation)
        }

        guard x1 >= 0, y1 >= 0, x2 <= Double(imageWidth), y2 <= Double(imageHeight) else {
            return .unusable(reason: .outOfBounds, dimensionRelation: relation)
        }

        return .usable(
            normalizedRect: CGRect(
                x: x1 / Double(imageWidth),
                y: y1 / Double(imageHeight),
                width: (x2 - x1) / Double(imageWidth),
                height: (y2 - y1) / Double(imageHeight)
            ),
            dimensionRelation: relation
        )
    }

    static func dimensionRelation(face: FaceBox, asset: Asset) -> DimensionRelation {
        guard let faceWidth = face.imageWidth, let faceHeight = face.imageHeight,
            faceWidth > 0, faceHeight > 0
        else {
            return .insufficientData
        }

        let referencePairs = [
            (asset.width, asset.height),
            (asset.exifInfo?.exifImageWidth, asset.exifInfo?.exifImageHeight)
        ].compactMap { width, height -> (Int, Int)? in
            guard let width, let height, width > 0, height > 0 else { return nil }
            return (width, height)
        }

        guard !referencePairs.isEmpty else {
            return .insufficientData
        }

        if referencePairs.contains(where: { $0.0 == faceWidth && $0.1 == faceHeight }) {
            return .match
        }

        if referencePairs.contains(where: { $0.0 == faceHeight && $0.1 == faceWidth }) {
            return .rotatedPair
        }

        return .mismatch
    }

    static func orientationCategory(_ orientation: String?) -> OrientationCategory {
        guard let orientation else { return .unknown }
        let normalized = orientation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "1", "2", "3", "4", "horizontal", "horizontal (normal)", "normal",
            "mirror horizontal", "rotate 180", "mirror vertical":
            return .uprightOr180
        case "5", "6", "7", "8", "mirror horizontal and rotate 270 cw", "rotate 90 cw",
            "mirror horizontal and rotate 90 cw", "rotate 270 cw":
            return .rotated90Or270
        default:
            return .unknown
        }
    }

    enum OrientationCategory: String, Equatable {
        case uprightOr180
        case rotated90Or270
        case unknown
    }
}
