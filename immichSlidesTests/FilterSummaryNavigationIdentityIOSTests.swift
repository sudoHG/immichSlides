#if os(iOS)
import Testing
@testable import immichSlides

@Suite
struct FilterSummaryNavigationIdentityIOSTests {
    @Test
    func `album and people entries use distinct stable identifiers`() {
        #expect(FilterSummarySelectionCardKind.album.accessibilityIdentifier == "filterSummary.album.button")
        #expect(FilterSummarySelectionCardKind.people.accessibilityIdentifier == "filterSummary.person.button")
        #expect(
            FilterSummarySelectionCardKind.album.accessibilityIdentifier
                != FilterSummarySelectionCardKind.people.accessibilityIdentifier)
    }

    @Test
    func `people entry case carries no associated selection count`() {
        #expect(Mirror(reflecting: FilterSummarySelectionCardKind.people).children.isEmpty)
    }
}
#endif
