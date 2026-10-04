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

    private static let counts = [0, 1, 2, 3, 4, 5, 9, 10, 12, 13, 40]

    // MARK: Distinct photos

    @Test
    func `distinct keeps the first occurrence of each photo in order`() {
        let input = [Self.photo(1), Self.photo(2), Self.photo(1), Self.photo(3), Self.photo(2)]
        #expect(CoverMosaicLayout.distinct(input) == [Self.photo(1), Self.photo(2), Self.photo(3)])
    }

    @Test
    func `distinct treats the same asset at another thumbnail size as one photo`() {
        let input = [Self.photo(1, size: "preview"), Self.photo(1, size: "fullsize"), Self.photo(2)]
        #expect(CoverMosaicLayout.distinct(input) == [Self.photo(1, size: "preview"), Self.photo(2)])
    }

    // MARK: iPad mosaic

    @Test
    func `tablet mosaic adapts its arrangement to the number of distinct photos`() {
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 0) == .empty)
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 1) == .single)
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 2) == .pair)
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 3) == .trio)
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 4) == .quad)
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 10) == .quad)
        #expect(CoverMosaicLayout.tabletArrangement(photoCount: 40) == .quad)
    }

    // MARK: tvOS preview strip

    @Test
    func `preview strip shows only the available photos up to its capacity`() {
        #expect(CoverMosaicLayout.stripPhotoCount(photoCount: 0) == 0)
        #expect(CoverMosaicLayout.stripPhotoCount(photoCount: 1) == 1)
        #expect(CoverMosaicLayout.stripPhotoCount(photoCount: 2) == 2)
        #expect(CoverMosaicLayout.stripPhotoCount(photoCount: 3) == 3)
        #expect(CoverMosaicLayout.stripPhotoCount(photoCount: 4) == 3)
        #expect(CoverMosaicLayout.stripPhotoCount(photoCount: 10) == 3)
    }

    // MARK: tvOS album wall

    @Test
    func `album wall never asks for more tiles than there are photos`() {
        for count in Self.counts {
            let plan = CoverMosaicLayout.albumWallPlan(photoCount: count)
            #expect(plan.topCount + plan.bottomCount == min(count, CoverMosaicLayout.albumWallCapacity))
            #expect(plan.topCount >= 0 && plan.bottomCount >= 0)
        }
    }

    @Test
    func `album wall keeps the full layout once there are enough photos`() {
        for count in [9, 10, 18, 40] {
            let plan = CoverMosaicLayout.albumWallPlan(photoCount: count)
            #expect(plan == CoverMosaicLayout.AlbumWallPlan(topCount: 4, bottomCount: 5, tileScale: 1))
        }
    }

    @Test
    func `album wall tiles grow as photos become fewer`() {
        var previousScale: CGFloat = 1
        for count in stride(from: 9, through: 1, by: -1) {
            let scale = CoverMosaicLayout.albumWallPlan(photoCount: count).tileScale
            #expect(scale >= previousScale)
            previousScale = scale
        }
        #expect(CoverMosaicLayout.albumWallPlan(photoCount: 1).tileScale > 1)
    }

    // MARK: tvOS people wall

    @Test
    func `people wall never asks for more tiles than there are photos`() {
        for count in Self.counts {
            let plan = CoverMosaicLayout.peopleWallPlan(photoCount: count)
            #expect(plan.rowCounts.reduce(0, +) == min(count, CoverMosaicLayout.peopleWallCapacity))
            #expect(plan.rowCounts.allSatisfy { $0 > 0 && $0 <= CoverMosaicLayout.peopleWallColumns })
        }
    }

    @Test
    func `people wall keeps the full grid once there are enough photos`() {
        for count in [12, 13, 36, 40] {
            let plan = CoverMosaicLayout.peopleWallPlan(photoCount: count)
            #expect(plan == CoverMosaicLayout.PeopleWallPlan(rowCounts: [4, 4, 4], tileScale: 1))
        }
    }

    @Test
    func `people wall tiles grow as photos become fewer`() {
        var previousScale: CGFloat = 1
        for count in stride(from: 12, through: 1, by: -1) {
            let scale = CoverMosaicLayout.peopleWallPlan(photoCount: count).tileScale
            #expect(scale >= previousScale)
            previousScale = scale
        }
        #expect(CoverMosaicLayout.peopleWallPlan(photoCount: 1).tileScale > 1)
    }

    // MARK: Spotlights

    @Test
    func `spotlight tiles keep their size at capacity and grow when fewer`() {
        let capacity = CoverMosaicLayout.albumSpotlightCapacity
        #expect(CoverMosaicLayout.spotlightScale(photoCount: capacity, capacity: capacity) == 1)
        #expect(CoverMosaicLayout.spotlightScale(photoCount: 10, capacity: capacity) == 1)
        #expect(
            CoverMosaicLayout.spotlightScale(photoCount: 2, capacity: capacity)
                > CoverMosaicLayout.spotlightScale(photoCount: 3, capacity: capacity))
        #expect(
            CoverMosaicLayout.spotlightScale(photoCount: 1, capacity: capacity)
                > CoverMosaicLayout.spotlightScale(photoCount: 2, capacity: capacity))
    }

    // MARK: Stage photo selection

    @Test
    func `stage photos never repeat a photo within the wall or the spotlights`() {
        let wall = [Self.photo(1), Self.photo(1), Self.photo(2)]
        let spotlights = [Self.photo(7), Self.photo(7), Self.photo(8)]
        let result = CoverMosaicLayout.stagePhotos(
            wall: wall, spotlights: spotlights, wallCapacity: 9, spotlightCapacity: 3)
        #expect(result.wall == [Self.photo(1), Self.photo(2)])
        #expect(result.spotlights == [Self.photo(7), Self.photo(8)])
    }

    @Test
    func `stage spotlights drop photos the short wall already shows`() {
        let wall = Self.photos(3)
        let spotlights = [Self.photo(1, size: "fullsize"), Self.photo(2), Self.photo(9)]
        let result = CoverMosaicLayout.stagePhotos(
            wall: wall, spotlights: spotlights, wallCapacity: 9, spotlightCapacity: 3)
        #expect(result.wall == wall)
        #expect(result.spotlights == [Self.photo(9)])
    }

    @Test
    func `stage keeps spotlights unchanged when the wall is full`() {
        let wall = Self.photos(12)
        let spotlights = Array(wall.prefix(4))
        let result = CoverMosaicLayout.stagePhotos(
            wall: wall, spotlights: spotlights, wallCapacity: 9, spotlightCapacity: 3)
        #expect(result.wall == Array(wall.prefix(9)))
        #expect(result.spotlights == Array(spotlights.prefix(3)))
    }

    @Test
    func `stage with no photos stays empty`() {
        let result = CoverMosaicLayout.stagePhotos(
            wall: [], spotlights: [], wallCapacity: 9, spotlightCapacity: 3)
        #expect(result.wall.isEmpty)
        #expect(result.spotlights.isEmpty)
    }
}
