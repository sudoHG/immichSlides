//
//  CodeAuditRegressionTests.swift
//  immichSlidesTests
//
//  Offline contracts for random-asset encoding, album-list decoding, test-server env gating,
//  photo render readiness, single-photo transform, and SmartFill slot readiness.
//

import CoreGraphics
import Foundation
import Testing
@testable import immichSlides

@MainActor
@Suite
struct CodeAuditRegressionTests {

    @Test
    func `random asset request does not encode isFavorite=false by default`() throws {
        // Default random includes favorites and non-favorites, so isFavorite must be nil and stay out of the body.

        let body = RandomAssetRequestBody(size: 10)
        let data = try JSONEncoder().encode(body)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(json["size"] as? Int == 10)
        #expect(json["isFavorite"] == nil)
    }

    @Test
    func `random asset request encodes isFavorite only when the favorite filter is explicitly set`() throws {
        let body = RandomAssetRequestBody(size: 10, isFavorite: true)
        let data = try JSONEncoder().encode(body)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(json["isFavorite"] as? Bool == true)
    }

    @Test
    func `album list decoding does not force-decode the full assets array`() throws {
        // Deliberately includes undecodable assets; lightweight decoding should ignore that field.

        let data = Data(
            """
            [
              {
                "id": "album-a",
                "albumName": "Family",
                "albumThumbnailAssetId": "thumb-a",
                "assetCount": 42,
                "assets": [
                  { "id": 123, "type": false, "unexpected": "heavy payload" }
                ]
              }
            ]
            """.utf8
        )

        let albums = try ImmichAPIService.decodeAlbumList(from: data)

        #expect(albums.count == 1)
        #expect(albums[0].id == "album-a")
        #expect(albums[0].albumName == "Family")
        #expect(albums[0].albumThumbnailAssetId == "thumb-a")
        #expect(albums[0].assetCount == 42)
        #expect(albums[0].assets.isEmpty)
    }

    @Test
    func `release and non-XCTest builds do not read the test server environment variables`() throws {
        let env = [
            "UI_TEST_SERVER_URL": " https://demo.example.com/ ",
            "UI_TEST_API_KEY": " test-key "
        ]

        let releaseLikeResult = ImmichServer.uiTestInjectedServerFromEnvironment(
            env,
            xctestSupportEnabled: false
        )
        #expect(releaseLikeResult == nil)

        let testResult = try #require(
            ImmichServer.uiTestInjectedServerFromEnvironment(
                env,
                xctestSupportEnabled: true
            )
        )
        #expect(testResult.immichURL == "https://demo.example.com/api")
        #expect(testResult.immichApiKey == "test-key")
    }

    @Test
    func `a photo renders only once its fullsize image is ready`() {
        #expect(SlideItemView.shouldRenderPhoto(fullsizeState: .readyToPlay))
        #expect(!SlideItemView.shouldRenderPhoto(fullsizeState: .downloading))
    }

    @Test
    func `single photo transform only consumes the shared active time and a new Reduce Motion layer returns identity`()
    {
        let profile = SceneAnimationProfile(
            lifecycle: SceneLifecycleContract(configuredInterval: 5)
        )
        let active = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: 2.5,
            isMotionEnabled: true
        )
        let reduced = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: 2.5,
            isMotionEnabled: false
        )

        #expect(!active.isIdentity)
        #expect(active.scale > 1)
        #expect(active.translationInSlot == .zero)
        #expect(active.anchorUnitPointInSlot == CGPoint(x: 0.5, y: 0.5))
        #expect(reduced.isIdentity)
    }

    @Test
    func `once single photo direction is fixed, the shared profile samples repeatably and independent of layout`() {
        let profile = SceneAnimationProfile(
            lifecycle: SceneLifecycleContract(configuredInterval: 5)
        )
        let zoomIn = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: 1.25,
            isMotionEnabled: true
        )
        let repeated = profile.singlePhotoTransform(
            direction: .zoomIn,
            activeTime: 1.25,
            isMotionEnabled: true
        )
        let zoomOut = profile.singlePhotoTransform(
            direction: .zoomOut,
            activeTime: 1.25,
            isMotionEnabled: true
        )

        #expect(zoomIn == repeated)
        #expect(zoomIn != zoomOut)
        #expect(zoomIn.translationInSlot == .zero)
        #expect(zoomOut.translationInSlot == .zero)
    }

    @Test
    func `SmartFill slot readiness only judges the slot display state and does not decide fallback`() {
        let readyURL = URL(fileURLWithPath: "/tmp/fullsize.jpg")

        #expect(
            PlaybackSmartFillSlotReadiness.resolve(
                assetId: "asset-ready",
                fullsizeState: .readyToPlay,
                fullsizeURL: readyURL
            ) == .ready(assetId: "asset-ready", fullsizeURL: readyURL)
        )
        #expect(
            PlaybackSmartFillSlotReadiness.resolve(
                assetId: "asset-pending",
                fullsizeState: .downloading,
                fullsizeURL: nil
            ) == .pending(assetId: "asset-pending")
        )
        #expect(
            PlaybackSmartFillSlotReadiness.resolve(
                assetId: "asset-failed",
                fullsizeState: .failedToDownload,
                fullsizeURL: nil
            ) == .failed(assetId: "asset-failed")
        )
    }
}
