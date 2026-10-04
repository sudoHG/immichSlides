//
//  FaceBoxGeometryTests.swift
//  immichSlidesTests
//
//  These tests only verify the coordinate geometry of Immich face boxes; they do not trigger playback, cropping
//  or UI behavior.
//

import CoreGraphics
import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct FaceBoxGeometryTests {
    private let coordinateTolerance: CGFloat = 0.000_001

    @Test
    func `every EXIF orientation code uses its axis category`() {
        for code in 1...8 {
            let expected: FaceBoxGeometry.OrientationCategory = code <= 4 ? .uprightOr180 : .rotated90Or270
            #expect(FaceBoxGeometry.orientationCategory(String(code)) == expected)
        }
    }

    @Test
    func `supported EXIF descriptions use their axis category`() {
        for description in [
            "Horizontal", "Horizontal (normal)", "Normal", "Mirror horizontal", "Rotate 180", "Mirror vertical"
        ] {
            #expect(FaceBoxGeometry.orientationCategory(description) == .uprightOr180)
        }
        for description in [
            "Mirror horizontal and rotate 270 CW", "Rotate 90 CW", "Mirror horizontal and rotate 90 CW", "Rotate 270 CW"
        ] {
            #expect(FaceBoxGeometry.orientationCategory(description) == .rotated90Or270)
        }
        #expect(FaceBoxGeometry.orientationCategory(" \nRoTaTe 90 cW\t") == .rotated90Or270)
        #expect(FaceBoxGeometry.orientationCategory(" 3\n") == .uprightOr180)
    }

    @Test
    func `malformed and unsupported orientations remain unknown`() {
        for orientation: String? in [
            nil, "", " \n", "0", "9", "10", "90", "270", "180", "unknown0", "abnormal", "not horizontal",
            "Rotate 900 CW", "Rotate 90 CW extra", "1.0", "01", "-1"
        ] {
            #expect(FaceBoxGeometry.orientationCategory(orientation) == .unknown)
        }
    }

    @Test
    func `ordinary pixel box maps to a normalized rect using the face image size`() throws {
        let asset = makeAsset(width: 4000, height: 3000, exifWidth: 4000, exifHeight: 3000, orientation: "1")
        let face = makeFace(x1: 100, x2: 500, y1: 300, y2: 900, imageWidth: 4000, imageHeight: 3000)

        let result = FaceBoxGeometry.validate(face: face, asset: asset)

        guard case let .usable(rect, relation) = result else {
            Issue.record("Expected a usable face box, got \(result)")
            return
        }
        #expect(abs(rect.minX - 0.025) < coordinateTolerance)
        #expect(abs(rect.minY - 0.1) < coordinateTolerance)
        #expect(abs(rect.width - 0.1) < coordinateTolerance)
        #expect(abs(rect.height - 0.2) < coordinateTolerance)
        #expect(relation == .match)
    }

    @Test
    func `multiple faces validate independently of each other`() {
        let asset = makeAsset(width: 1000, height: 800, exifWidth: 1000, exifHeight: 800, orientation: "1")
        let faces = [
            makeFace(id: "valid-a", x1: 10, x2: 110, y1: 20, y2: 220, imageWidth: 1000, imageHeight: 800),
            makeFace(id: "reversed", x1: 300, x2: 200, y1: 20, y2: 220, imageWidth: 1000, imageHeight: 800),
            makeFace(id: "valid-b", x1: 400, x2: 500, y1: 100, y2: 200, imageWidth: 1000, imageHeight: 800)
        ]

        let results = FaceBoxGeometry.validate(faces: faces, asset: asset)

        #expect(results.count == 3)
        #expect(results[0].isUsable)
        #expect(results[1] == .unusable(reason: .invalidCoordinateOrder, dimensionRelation: .match))
        #expect(results[2].isUsable)
    }

    @Test
    func `missing coordinates make the face box unusable`() {
        let result = FaceBoxGeometry.validate(
            face: makeFace(x1: nil, x2: 20, y1: 5, y2: 25, imageWidth: 100, imageHeight: 100),
            asset: makeAsset(width: 100, height: 100, exifWidth: 100, exifHeight: 100, orientation: "1")
        )

        #expect(result == .unusable(reason: .missingCoordinates, dimensionRelation: .match))
    }

    @Test
    func `zero or missing face image dimensions make the box unusable`() {
        let asset = makeAsset(width: 100, height: 100, exifWidth: 100, exifHeight: 100, orientation: "1")

        #expect(
            FaceBoxGeometry.validate(
                face: makeFace(x1: 1, x2: 20, y1: 1, y2: 20, imageWidth: 0, imageHeight: 100),
                asset: asset
            ) == .unusable(reason: .invalidImageDimensions, dimensionRelation: .insufficientData))

        #expect(
            FaceBoxGeometry.validate(
                face: makeFace(x1: 1, x2: 20, y1: 1, y2: 20, imageWidth: 100, imageHeight: nil),
                asset: asset
            ) == .unusable(reason: .invalidImageDimensions, dimensionRelation: .insufficientData))
    }

    @Test
    func `out of bounds or reversed coordinates make the box unusable`() {
        let asset = makeAsset(width: 100, height: 100, exifWidth: 100, exifHeight: 100, orientation: "1")

        #expect(
            FaceBoxGeometry.validate(
                face: makeFace(x1: -1, x2: 20, y1: 1, y2: 20, imageWidth: 100, imageHeight: 100),
                asset: asset
            ) == .unusable(reason: .outOfBounds, dimensionRelation: .match))

        #expect(
            FaceBoxGeometry.validate(
                face: makeFace(x1: 30, x2: 20, y1: 1, y2: 20, imageWidth: 100, imageHeight: 100),
                asset: asset
            ) == .unusable(reason: .invalidCoordinateOrder, dimensionRelation: .match))
    }

    @Test
    func `face box is usable with a match relation when face, asset, and EXIF sizes agree`() {
        let result = FaceBoxGeometry.validate(
            face: makeFace(x1: 10, x2: 110, y1: 20, y2: 220, imageWidth: 1000, imageHeight: 800),
            asset: makeAsset(width: 1000, height: 800, exifWidth: 1000, exifHeight: 800, orientation: "Horizontal")
        )

        guard case let .usable(_, relation) = result else {
            Issue.record("Expected matching dimensions to be usable, got \(result)")
            return
        }
        #expect(relation == .match)
    }

    @Test
    func `a 90 or 270 degree rotated face box still normalizes against its own image dimensions`() {
        let result = FaceBoxGeometry.validate(
            face: makeFace(x1: 10, x2: 110, y1: 20, y2: 220, imageWidth: 3000, imageHeight: 4000),
            asset: makeAsset(width: 4000, height: 3000, exifWidth: 4000, exifHeight: 3000, orientation: "Rotate 90 CW")
        )

        guard case let .usable(rect, relation) = result else {
            Issue.record("Expected a usable rotated pair face box, got \(result)")
            return
        }
        #expect(relation == .rotatedPair)
        #expect(abs(rect.minX - (10.0 / 3000.0)) < coordinateTolerance)
        #expect(abs(rect.minY - (20.0 / 4000.0)) < coordinateTolerance)
    }

    @Test
    func `a preview scaled face box normalizes against its own image dimensions`() {
        let result = FaceBoxGeometry.validate(
            face: makeFace(x1: 682, x2: 848, y1: 227, y2: 456, imageWidth: 1440, imageHeight: 2160),
            asset: makeAsset(width: 5120, height: 7168, exifWidth: 7168, exifHeight: 5120, orientation: "8")
        )

        guard case let .usable(rect, relation) = result else {
            Issue.record("Expected a usable face box in preview coordinates, got \(result)")
            return
        }
        #expect(relation == .mismatch)
        #expect(abs(rect.minX - (682.0 / 1440.0)) < coordinateTolerance)
        #expect(abs(rect.minY - (227.0 / 2160.0)) < coordinateTolerance)
        #expect(abs(rect.width - (166.0 / 1440.0)) < coordinateTolerance)
        #expect(abs(rect.height - (229.0 / 2160.0)) < coordinateTolerance)
    }

    @Test
    func `unknown orientation with mismatched dimensions still recovers a usable box from its own image dimensions`() {
        let result = FaceBoxGeometry.validate(
            face: makeFace(x1: 10, x2: 110, y1: 20, y2: 220, imageWidth: 1200, imageHeight: 900),
            asset: makeAsset(width: 1000, height: 800, exifWidth: 1000, exifHeight: 800, orientation: nil)
        )

        guard case let .usable(rect, relation) = result else {
            Issue.record("Expected a usable mismatch face box, got \(result)")
            return
        }
        #expect(relation == .mismatch)
        #expect(abs(rect.width - (100.0 / 1200.0)) < coordinateTolerance)
        #expect(abs(rect.height - (200.0 / 900.0)) < coordinateTolerance)
    }

    @Test
    func `people present without faces yields no face protection input`() {
        let people = [
            People(id: "person-a", name: "redacted", isHidden: false, isFavorite: false, faces: nil)
        ]

        #expect(FaceBoxGeometry.collectFaces(from: people).isEmpty)
    }

    private func makeAsset(
        width: Int?,
        height: Int?,
        exifWidth: Int?,
        exifHeight: Int?,
        orientation: String?
    ) -> Asset {
        Asset(
            id: "asset-fixture",
            type: "IMAGE",
            isFavorite: false,
            isTrashed: false,
            isArchived: false,
            exifInfo: ExifInfo(exifImageWidth: exifWidth, exifImageHeight: exifHeight, orientation: orientation),
            people: nil,
            tags: nil,
            livePhotoVideoID: nil,
            width: width,
            height: height
        )
    }

    private func makeFace(
        id: String? = nil,
        x1: Double?,
        x2: Double?,
        y1: Double?,
        y2: Double?,
        imageWidth: Int?,
        imageHeight: Int?
    ) -> FaceBox {
        FaceBox(
            id: id,
            boundingBoxX1: x1,
            boundingBoxX2: x2,
            boundingBoxY1: y1,
            boundingBoxY2: y2,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            sourceType: "machine-learning"
        )
    }
}
