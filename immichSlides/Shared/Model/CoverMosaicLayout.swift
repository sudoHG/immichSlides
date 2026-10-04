import CoreGraphics
import Foundation

/// Decides how many distinct cover photos the filter-entry mosaics show and how large their tiles are.
/// A photo never appears twice: fewer photos mean fewer, larger tiles instead of repeated ones.
enum CoverMosaicLayout {
    enum TabletArrangement: Equatable {
        case empty
        case single
        case pair
        case trio
        case quad
    }

    struct AlbumWallPlan: Equatable {
        let topCount: Int
        let bottomCount: Int
        let tileScale: CGFloat
    }

    struct PeopleWallPlan: Equatable {
        let rowCounts: [Int]
        let tileScale: CGFloat
    }

    struct StagePhotos: Equatable {
        let wall: [URL]
        let spotlights: [URL]
    }

    static let stripCapacity = 3
    static let albumWallTopCapacity = 4
    static let albumWallCapacity = 9
    static let albumSpotlightCapacity = 3
    static let peopleWallColumns = 4
    static let peopleWallCapacity = 12
    static let peopleSpotlightCapacity = 3

    private static let maximumTileEnlargement: CGFloat = 1.5

    /// The asset path identifies a photo, so the same asset at another thumbnail size is the same photo.
    static func photoIdentity(of url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    static func distinct(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert(photoIdentity(of: $0)).inserted }
    }

    static func tabletArrangement(photoCount: Int) -> TabletArrangement {
        switch photoCount {
        case ...0: return .empty
        case 1: return .single
        case 2: return .pair
        case 3: return .trio
        default: return .quad
        }
    }

    static func stripPhotoCount(photoCount: Int) -> Int {
        min(max(photoCount, 0), stripCapacity)
    }

    static func albumWallPlan(photoCount: Int) -> AlbumWallPlan {
        let shown = min(max(photoCount, 0), albumWallCapacity)
        let topCount = shown >= albumWallCapacity ? albumWallTopCapacity : shown / 2
        return AlbumWallPlan(
            topCount: topCount,
            bottomCount: shown - topCount,
            tileScale: tileScale(photoCount: shown, capacity: albumWallCapacity)
        )
    }

    static func peopleWallPlan(photoCount: Int) -> PeopleWallPlan {
        let shown = min(max(photoCount, 0), peopleWallCapacity)
        let rowCount = (shown + peopleWallColumns - 1) / peopleWallColumns
        let rowCounts = (0..<rowCount).map { row in
            shown / rowCount + (row < shown % rowCount ? 1 : 0)
        }
        return PeopleWallPlan(
            rowCounts: rowCounts,
            tileScale: tileScale(photoCount: shown, capacity: peopleWallCapacity)
        )
    }

    static func spotlightScale(photoCount: Int, capacity: Int) -> CGFloat {
        tileScale(photoCount: photoCount, capacity: capacity)
    }

    /// Wall and spotlights each keep distinct photos. A short wall also hides spotlights it already
    /// shows; a full wall keeps the original layering where spotlights may reuse wall photos.
    static func stagePhotos(
        wall: [URL], spotlights: [URL], wallCapacity: Int, spotlightCapacity: Int
    ) -> StagePhotos {
        let wallPhotos = Array(distinct(wall).prefix(wallCapacity))
        var spotlightPhotos = distinct(spotlights)
        if wallPhotos.count < wallCapacity {
            let shown = Set(wallPhotos.map(photoIdentity(of:)))
            spotlightPhotos.removeAll { shown.contains(photoIdentity(of: $0)) }
        }
        return StagePhotos(wall: wallPhotos, spotlights: Array(spotlightPhotos.prefix(spotlightCapacity)))
    }

    private static func tileScale(photoCount: Int, capacity: Int) -> CGFloat {
        guard photoCount > 0, photoCount < capacity else { return 1 }
        return min(maximumTileEnlargement, (CGFloat(capacity) / CGFloat(photoCount)).squareRoot())
    }
}
