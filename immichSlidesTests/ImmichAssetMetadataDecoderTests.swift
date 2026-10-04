//
//  ImmichAssetMetadataDecoderTests.swift
//  immichSlidesTests
//
//  These tests only cover pure Codable decoding of Immich asset metadata JSON.
//

import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct ImmichAssetMetadataDecoderTests {

    @Test
    func `complete metadata decodes asset dimensions, EXIF dimensions, orientation, and person face boxes`() throws {
        let asset = try decodeFixture("normal-metadata")

        #expect(asset.id == "fixture-asset-001")
        #expect(asset.width == 4000)
        #expect(asset.height == 3000)
        #expect(asset.exifInfo?.exifImageWidth == 4000)
        #expect(asset.exifInfo?.exifImageHeight == 3000)
        #expect(asset.exifInfo?.orientation == "Rotate 90 CW")

        let person = try #require(asset.people?.first)
        #expect(person.faces?.count == 1)

        let face = try #require(person.faces?.first)
        #expect(face.id == "fixture-face-001")
        #expect(face.boundingBoxX1 == 100.5)
        #expect(face.boundingBoxX2 == 420.25)
        #expect(face.boundingBoxY1 == 80.0)
        #expect(face.boundingBoxY2 == 390.75)
        #expect(face.imageWidth == 4000)
        #expect(face.imageHeight == 3000)
        #expect(face.sourceType == "machine-learning")
    }

    @Test
    func `old JSON missing metadata keeps the new fields nil`() throws {
        let asset = try decodeFixture("missing-metadata")

        #expect(asset.width == nil)
        #expect(asset.height == nil)
        #expect(asset.exifInfo == nil)
        #expect(asset.people == nil)
    }

    @Test
    func `nil, zero, unknown fields, and numeric orientation decode safely`() throws {
        let asset = try decodeFixture("nil-zero-unknown")

        #expect(asset.width == 0)
        #expect(asset.height == nil)
        #expect(asset.exifInfo?.exifImageWidth == 0)
        #expect(asset.exifInfo?.exifImageHeight == nil)
        #expect(asset.exifInfo?.orientation == "1")

        let face = try #require(asset.people?.first?.faces?.first)
        #expect(face.id == nil)
        #expect(face.boundingBoxX1 == nil)
        #expect(face.boundingBoxX2 == 0)
        #expect(face.boundingBoxY1 == nil)
        #expect(face.boundingBoxY2 == 0)
        #expect(face.imageWidth == nil)
        #expect(face.imageHeight == 0)
        #expect(face.sourceType == nil)
    }

    @Test
    func `an empty exifInfo object decodes without inventing a camera make or model`() throws {
        let json = Data(
            """
            {"id":"asset-a-2","type":"IMAGE","isFavorite":false,"isTrashed":false,"isArchived":false,"width":180,"height":320,"exifInfo":{}}
            """.utf8
        )
        let asset = try JSONDecoder().decode(Asset.self, from: json)
        #expect(asset.id == "asset-a-2")
        #expect(asset.exifInfo != nil)
        #expect(asset.exifInfo?.make == nil)
        #expect(asset.exifInfo?.model == nil)
        #expect(asset.exifInfo?.dateTimeOriginal == nil)
    }

    @Test
    func `a person missing the faces field keeps faces nil`() throws {
        let asset = try decodeFixture("people-without-faces")

        let person = try #require(asset.people?.first)
        #expect(person.id == "fixture-person-003")
        #expect(person.faces == nil)
    }

    private func decodeFixture(_ name: String) throws -> Asset {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ImmichAssetMetadata/\(name).json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(Asset.self, from: fixtureData)
    }
}
