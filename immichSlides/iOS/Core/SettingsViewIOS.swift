import SwiftUI

// The iOS settings screen hosts platform-specific category navigation; state stays in the shared SettingsView.

struct SettingsViewIOS: View {

    let isPhoneLayout: Bool

    @Binding var selectedSelection: SettingSelection?

    @Binding var isShowingOpenSourceLicenses: Bool

    let detailView: (SettingSelection) -> AnyView
    let openSourceLicensesView: () -> AnyView

    let settingsItemAccessibilityID: (SettingSelection) -> String
    // iPad shows open source licenses without a NavigationStack path, so path and UI cannot desync after going back.

    @State private var isShowingPadOpenSourceLicenses = false
    @State private var detailStackIdentity = UUID()

    var body: some View {
        Group {
            if isPhoneLayout {
                phoneLayout
            } else {
                padLayout
            }
        }
    }

    private var phoneLayout: some View {
        List {
            Section {
                ForEach(SettingSelection.allCases) { selection in
                    NavigationLink {
                        detailView(selection)
                            .navigationDestination(isPresented: $isShowingOpenSourceLicenses) {
                                openSourceLicensesView()
                                    // On iPhone, reset isPresented manually when returning from licenses;
                                    // if it stays true, the next push cannot happen.

                                    .onDisappear {
                                        isShowingOpenSourceLicenses = false
                                    }
                            }
                            .navigationTitle(selection.title)
                            .appNavigationBarTitleDisplayModeInline()
                    } label: {
                        Label(selection.title, systemImage: selection.icon)
                            .accessibilityIdentifier(settingsItemAccessibilityID(selection))
                    }
                }
            }
        }
        .appListStyleInsetGrouped()
        .navigationTitle("Settings")
    }

    private var padLayout: some View {
        NavigationSplitView {
            List(selection: $selectedSelection) {
                Section {
                    ForEach(SettingSelection.allCases) { selection in
                        Label(selection.title, systemImage: selection.icon)
                            .font(.body)
                            .tag(selection)
                            .accessibilityIdentifier(settingsItemAccessibilityID(selection))
                    }
                }
            }
            .appListStyleSidebar()
            .navigationTitle("Settings")
        } detail: {
            // The detail column owns its NavigationStack: the sidebar handles top-level categories,
            // the detail column handles titles and second-level pages.

            NavigationStack {
                Group {
                    if isShowingPadOpenSourceLicenses {
                        // On iPad, open source licenses swap the detail content instead of pushing a path.

                        openSourceLicensesView()
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button {
                                        isShowingPadOpenSourceLicenses = false
                                    } label: {
                                        Label("About", systemImage: "chevron.left")
                                    }
                                    .accessibilityIdentifier("settings.about.opensource.back.button")
                                }
                            }
                    } else {
                        detailView(selectedSelection ?? .playback)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(PlatformCompat.systemGroupedBackground)
            }
            .id(detailStackIdentity)
            .onChange(of: isShowingOpenSourceLicenses) { _, shouldOpen in
                guard shouldOpen else { return }

                // The Bool is only an open request from the About row; swap the detail content, then clear it.

                isShowingPadOpenSourceLicenses = true
                isShowingOpenSourceLicenses = false
            }
            .onChange(of: selectedSelection) { _, _ in
                isShowingOpenSourceLicenses = false
                isShowingPadOpenSourceLicenses = false
                detailStackIdentity = UUID()
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
