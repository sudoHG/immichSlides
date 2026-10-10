import XCTest

private enum WaitTiming {
    static let defaultSnapshotTimeoutSeconds: TimeInterval = TestWait.seconds(.product(30))
    static let selectionChangeTimeoutSeconds: TimeInterval = TestWait.seconds(.product(3))
    static let selectionPollSeconds: TimeInterval = TestWait.seconds(.product(0.25))
    static let snapshotPollSeconds: TimeInterval = TestWait.seconds(.product(0.5))
}

/// The album filter cards as one snapshot of the app shows them.
///
/// A card shows its cover aspect-filled and clipped. Clipping hides the overflow on screen, but a portrait or
/// panoramic cover still reaches over the neighbouring cards unless the card limits its accessibility frame and
/// tap area to itself.
struct AlbumCardSnapshot: Equatable {
    struct Card: Equatable {
        let identifier: String
        let frame: CGRect
        /// The card's largest image without an identifier, which is the cover; it has no size until the cover loads.
        /// XCUITest reports its unclipped size, which is how these checks see whether a cover overflows the card.
        let coverFrame: CGRect?
        let hasFocus: Bool
        let isSelected: Bool
    }

    /// Rounding and the card outline stay within this many points.
    static let tolerance: CGFloat = 2
    /// Cards sit apart in the grid, so frames that overlap by more than rounding reach into each other.
    static let overlapTolerance: CGFloat = 0.5
    /// Allowed relative difference between two width-to-height ratios that count as the same shape.
    static let aspectRatioTolerance: CGFloat = 0.03

    let screenFrame: CGRect
    /// The lowest edge of the page's back button, above which cards can sit under the top bar.
    let topBarBottom: CGFloat
    /// The cards in the order the snapshot lists them.
    let cards: [Card]

    @MainActor
    init(app: XCUIApplication) throws {
        let snapshot = try app.snapshot()
        var cards: [Card] = []
        var topBarBottom = snapshot.frame.minY
        func collect(_ element: any XCUIElementSnapshot) {
            let identifier = element.identifier
            if identifier == "albumFilter.back.button" {
                topBarBottom = max(topBarBottom, element.frame.maxY)
            }
            guard element.elementType == .button, identifier.hasPrefix("albumFilter.album."),
                identifier.hasSuffix(".button")
            else {
                element.children.forEach(collect)
                return
            }
            let cover = element.children
                .filter { $0.elementType == .image && $0.identifier.isEmpty }
                .map(\.frame)
                .max { $0.width * $0.height < $1.width * $1.height }
            cards.append(
                Card(
                    identifier: identifier, frame: element.frame, coverFrame: cover, hasFocus: element.hasFocus,
                    isSelected: element.isSelected))
        }
        collect(snapshot)
        self.screenFrame = snapshot.frame
        self.topBarBottom = topBarBottom
        self.cards = cards
    }

    /// The size most unfocused cards share, which is the grid's card size when every frame matches its card.
    var commonCardSize: CGSize? {
        let unfocused = cards.filter { !$0.hasFocus }
        let sizes = (unfocused.isEmpty ? cards : unfocused).map {
            [Int($0.frame.width.rounded()), Int($0.frame.height.rounded())]
        }
        guard let common = Dictionary(grouping: sizes, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key
        else { return nil }
        return CGSize(width: common[0], height: common[1])
    }

    /// Whether an on-screen card's cover has not loaded yet: a loaded cover fills its card in both directions.
    func hasUnloadedCover(cardSize: CGSize) -> Bool {
        cards.contains { card in
            guard let cover = card.coverFrame, card.frame.intersects(screenFrame) else { return false }
            return cover.width < cardSize.width - Self.tolerance || cover.height < cardSize.height - Self.tolerance
        }
    }

    /// Whether a loaded cover has another shape than the card, so that filling the card makes it overflow.
    /// Comparing shapes rather than sizes keeps a focused card, which is only scaled, from counting.
    func hasOverflowingCover(cardSize: CGSize) -> Bool {
        let cardAspectRatio = cardSize.width / cardSize.height
        return cards.contains { card in
            guard let cover = card.coverFrame, cover.width > 0, cover.height > 0 else { return false }
            let isLoaded =
                cover.width >= cardSize.width - Self.tolerance && cover.height >= cardSize.height - Self.tolerance
            return isLoaded && abs(cover.width / cover.height / cardAspectRatio - 1) > Self.aspectRatioTolerance
        }
    }

    /// Whether the cards match the previous snapshot and every on-screen cover has loaded.
    func isSettled(since previous: AlbumCardSnapshot?) -> Bool {
        guard self == previous, let cardSize = commonCardSize else { return false }
        return !hasUnloadedCover(cardSize: cardSize)
    }

    /// Takes snapshots 0.5 s apart until two match and every on-screen cover has loaded. At the timeout it fails the
    /// test if the cards are still moving, and otherwise returns the last snapshot, whose covers may not all have
    /// loaded: a cover the server cannot provide must not fail the test when other covers can be checked.
    @MainActor
    static func settled(
        in app: XCUIApplication, timeout: TimeInterval, file: StaticString, line: UInt
    ) throws -> AlbumCardSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: AlbumCardSnapshot?
        var current = try AlbumCardSnapshot(app: app)
        while Date() < deadline, !current.isSettled(since: previous) {
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.snapshotPollSeconds))
            previous = current
            current = try AlbumCardSnapshot(app: app)
        }
        guard current == previous else {
            XCTFail("The album cards were still moving after \(Int(timeout)) seconds", file: file, line: line)
            return nil
        }
        return current
    }

    /// The common card size once some loaded cover has another shape than the card. Fails when there are no cards,
    /// when the snapshot shows no cover images or when covers did not load, and skips when every loaded cover has the
    /// card's shape.
    static func requireOverflowingCover(
        in snapshot: AlbumCardSnapshot, timeout: TimeInterval, file: StaticString, line: UInt
    ) throws -> CGSize? {
        guard let cardSize = snapshot.commonCardSize else {
            XCTFail("The album filter page shows no album cards", file: file, line: line)
            return nil
        }
        guard snapshot.cards.contains(where: { $0.coverFrame != nil }) else {
            XCTFail(
                "The snapshot shows no cover image inside the album cards, so no cover can be checked", file: file,
                line: line)
            return nil
        }
        if snapshot.hasOverflowingCover(cardSize: cardSize) {
            return cardSize
        }
        if snapshot.hasUnloadedCover(cardSize: cardSize) {
            XCTFail("Album covers did not load within \(Int(timeout)) seconds", file: file, line: line)
            return nil
        }
        throw XCTSkip("No loaded album cover is portrait or panoramic, so no cover overflows its card.")
    }

    /// Checks that no card's frame reaches into another card, then that every card keeps the common card size
    /// (a focused card its shape).
    @MainActor
    static func assertFramesIgnoreCoverShape(
        in app: XCUIApplication,
        timeout: TimeInterval = WaitTiming.defaultSnapshotTimeoutSeconds,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let snapshot = try settled(in: app, timeout: timeout, file: file, line: line) else { return }
        // The overlap check needs no common size, so it also catches frames that all grew the same way.
        for (index, card) in snapshot.cards.enumerated() {
            for other in snapshot.cards[(index + 1)...]
            where card.frame.insetBy(dx: overlapTolerance, dy: overlapTolerance).intersects(other.frame) {
                XCTFail("\(card.identifier) reaches into \(other.identifier)", file: file, line: line)
            }
        }
        guard let cardSize = try requireOverflowingCover(in: snapshot, timeout: timeout, file: file, line: line)
        else { return }
        let cardAspectRatio = cardSize.width / cardSize.height
        for card in snapshot.cards {
            let name = card.identifier
            if card.hasFocus {
                // Focus scales a card evenly, so its frame keeps the card's shape whatever its size.
                let aspectRatio = card.frame.width / card.frame.height
                XCTAssertEqual(
                    aspectRatio / cardAspectRatio, 1, accuracy: aspectRatioTolerance, name, file: file, line: line)
            } else {
                XCTAssertEqual(card.frame.width, cardSize.width, accuracy: tolerance, name, file: file, line: line)
                XCTAssertEqual(card.frame.height, cardSize.height, accuracy: tolerance, name, file: file, line: line)
            }
        }
    }
}

#if os(iOS)
// Taps: iOS and iPadOS only, since tvOS moves focus instead of taking taps.
extension AlbumCardSnapshot {
    /// A point inside one card that another card's cover also covers.
    struct CoverOverlap {
        let card: Card
        let coverOwner: Card
        let point: CGPoint
    }

    /// How far a tap point stays inside the edges of the card it targets, in points.
    static let tapInset: CGFloat = 4

    /// The card area the user sees: the common card size, centred on the card's frame, which stays centred on the
    /// card even when a cover stretches the frame.
    func visibleRect(of card: Card, cardSize: CGSize) -> CGRect {
        CGRect(
            x: card.frame.midX - cardSize.width / 2, y: card.frame.midY - cardSize.height / 2,
            width: cardSize.width, height: cardSize.height)
    }

    /// Points inside an unfocused card, below the top bar and on screen, that the cover of a later card in the grid
    /// also covers. A later card is drawn above an earlier one, so these are the points where its cover could take the
    /// tap; an earlier card's cover lies underneath and cannot.
    func coverOverlaps(cardSize: CGSize) -> [CoverOverlap] {
        let reachable = screenFrame.intersection(
            CGRect(
                x: screenFrame.minX, y: topBarBottom, width: screenFrame.width, height: screenFrame.maxY - topBarBottom)
        )
        var overlaps: [CoverOverlap] = []
        for card in cards where !card.hasFocus {
            let target = visibleRect(of: card, cardSize: cardSize)
                .insetBy(dx: Self.tapInset, dy: Self.tapInset)
                .intersection(reachable)
            for owner in cards where comesLater(owner, than: card) {
                guard let cover = owner.coverFrame else { continue }
                let shared = target.intersection(cover)
                guard !shared.isNull, shared.width > 0, shared.height > 0 else { continue }
                overlaps.append(
                    CoverOverlap(card: card, coverOwner: owner, point: CGPoint(x: shared.midX, y: shared.midY)))
            }
        }
        return overlaps
    }

    /// Whether `card` comes after `other` in the grid: in a lower row, or further right in the same row. The app has no
    /// right-to-left localization.
    private func comesLater(_ card: Card, than other: Card) -> Bool {
        if abs(card.frame.midY - other.frame.midY) > Self.tolerance {
            return card.frame.midY > other.frame.midY
        }
        return card.frame.midX > other.frame.midX
    }

    /// Taps inside cards where the cover of a later card overflows, and checks that each tap selects or clears the
    /// tapped card only. A tap that changed the selection is repeated to undo it.
    @MainActor
    static func assertTapsIgnoreCoverShape(
        in app: XCUIApplication,
        maximumTaps: Int = 4,
        timeout: TimeInterval = WaitTiming.defaultSnapshotTimeoutSeconds,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard let snapshot = try settled(in: app, timeout: timeout, file: file, line: line),
            let cardSize = try requireOverflowingCover(in: snapshot, timeout: timeout, file: file, line: line)
        else { return }
        let overlaps = snapshot.coverOverlaps(cardSize: cardSize)
        guard !overlaps.isEmpty else {
            throw XCTSkip("No album cover overflows into an earlier card below the top bar.")
        }
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        for overlap in overlaps.prefix(maximumTaps) {
            let tap = origin.withOffset(CGVector(dx: overlap.point.x, dy: overlap.point.y))
            let before = try selection(in: app)
            tap.tap()
            let changed = try waitForSelectionChange(in: app, from: before)
            XCTAssertEqual(
                changed, [overlap.card.identifier],
                "Tap at \(overlap.point) inside \(overlap.card.identifier), under \(overlap.coverOwner.identifier)'s cover",
                file: file, line: line)
            guard !changed.isEmpty else { continue }
            tap.tap()
            XCTAssertTrue(
                try waitForSelection(in: app, toEqual: before),
                "The second tap at \(overlap.point) should undo the first",
                file: file, line: line)
        }
    }

    @MainActor
    private static func selection(in app: XCUIApplication) throws -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: try AlbumCardSnapshot(app: app).cards.map { ($0.identifier, $0.isSelected) })
    }

    /// The cards whose selection differs from `before`, once one does or after 3 s.
    @MainActor
    private static func waitForSelectionChange(in app: XCUIApplication, from before: [String: Bool]) throws -> [String]
    {
        let deadline = Date().addingTimeInterval(WaitTiming.selectionChangeTimeoutSeconds)
        var changed: [String] = []
        while changed.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.selectionPollSeconds))
            let now = try selection(in: app)
            changed = now.keys.filter { now[$0] != before[$0] }.sorted()
        }
        return changed
    }

    /// Whether the selection returns to `expected` within 3 s.
    @MainActor
    private static func waitForSelection(in app: XCUIApplication, toEqual expected: [String: Bool]) throws -> Bool {
        let deadline = Date().addingTimeInterval(WaitTiming.selectionChangeTimeoutSeconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(WaitTiming.selectionPollSeconds))
            if try selection(in: app) == expected { return true }
        }
        return false
    }
}
#endif
