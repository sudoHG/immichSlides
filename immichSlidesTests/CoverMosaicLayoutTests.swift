import Foundation
import Testing
@testable import immichSlides

@MainActor
struct CoverMosaicLayoutTests {
    private static func photo(_ id: Int, size: String = "preview") -> URL {
        URL(string: "https://immich.example.test/api/assets/asset-\(id)/thumbnail?size=\(size)")!
    }

    private static func photos(_ count: Int) -> [URL] {
        (0..<count).map { photo($0) }
    }

    @Test
    func `distinct keeps the first occurrence and treats another thumbnail size as the same photo`() {
        let input = [
            Self.photo(1, size: "preview"), Self.photo(2), Self.photo(1, size: "fullsize"), Self.photo(3),
            Self.photo(2)
        ]
        #expect(CoverMosaicLayout.distinct(input) == [Self.photo(1), Self.photo(2), Self.photo(3)])
    }

    @Test
    func `tablet mosaic adapts its arrangement to the number of distinct photos`() {
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 0) == .empty)
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 1) == .single)
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 2) == .pair)
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 3) == .trio)
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 4) == .quad)
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 10) == .quad)
    }

    @Test
    func `preview strip shows only the available photos up to its capacity`() {
        let counts = [0, 1, 2, 3, 4, 10].map { CoverMosaicLayout.stripPhotoCount(photoCount: $0) }
        #expect(counts == [0, 1, 2, 3, 3, 3])
    }

    @Test
    func `album wall never asks for more tiles than there are photos and keeps the full layout`() {
        for count in [0, 1, 2, 3, 5, 8] {
            let plan = CoverMosaicLayout.albumWallPlan(photoCount: count)
            #expect(plan.topCount + plan.bottomCount == count)
            #expect(count == 0 || plan.tileScale > 1)
        }
        for count in [9, 10, 40] {
            #expect(
                CoverMosaicLayout.albumWallPlan(photoCount: count)
                    == CoverMosaicLayout.AlbumWallPlan(topCount: 4, bottomCount: 5, tileScale: 1))
        }
    }

    @Test
    func `people wall never asks for more tiles than there are photos and keeps the full grid`() {
        for count in [0, 1, 2, 3, 5, 11] {
            let plan = CoverMosaicLayout.peopleWallPlan(photoCount: count)
            #expect(plan.rowCounts.reduce(0, +) == count)
            #expect(plan.rowCounts.allSatisfy { $0 > 0 && $0 <= CoverMosaicLayout.peopleWallColumns })
            #expect(count == 0 || plan.tileScale > 1)
        }
        for count in [12, 13, 40] {
            #expect(
                CoverMosaicLayout.peopleWallPlan(photoCount: count)
                    == CoverMosaicLayout.PeopleWallPlan(rowCounts: [4, 4, 4], tileScale: 1))
        }
    }

    @Test
    func `stage photos never repeat and a short wall hides the spotlights it already shows`() {
        let shortWall = Self.photos(3)
        let shortResult = CoverMosaicLayout.stagePhotos(
            wall: shortWall + [Self.photo(1)],
            spotlights: [Self.photo(1, size: "fullsize"), Self.photo(2), Self.photo(9), Self.photo(9)],
            wallCapacity: 9, spotlightCapacity: 3)
        #expect(shortResult.wall == shortWall)
        #expect(shortResult.spotlights == [Self.photo(9)])

        let fullWall = Self.photos(12)
        let fullResult = CoverMosaicLayout.stagePhotos(
            wall: fullWall, spotlights: Array(fullWall.prefix(4)), wallCapacity: 9, spotlightCapacity: 3)
        #expect(fullResult.wall == Array(fullWall.prefix(9)))
        #expect(fullResult.spotlights == Array(fullWall.prefix(3)))
    }
}
