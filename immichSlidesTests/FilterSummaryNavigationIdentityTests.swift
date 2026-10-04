#if os(iOS)
import Testing
@testable import immichSlides

@Suite
struct FilterSummaryNavigationIdentityTests {
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

    @Test(
        .disabled(
            "Old path/Binding types removed; verify page identity and back target after selection with runtime UI; unit tests cannot prove NavigationLink behavior"
        )
    )
    func `selecting a person stays on the people page and back only exits that page`() {
        Issue.record("Pending runtime UI verification.")
    }
}
#endif
