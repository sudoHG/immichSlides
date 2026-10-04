import SwiftUI

extension SettingsViewTV {
    func playbackActionButton(
        title: String,
        value: String,
        valueTint: Color = .secondary,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        // Custom-focus rows don't use the system Button, to avoid the white shell overflowing the bounds.

        TVSettingsFocusableControl(
            accessibilityLabel: title,
            accessibilityValue: value,
            accessibilityIdentifier: accessibilityIdentifier,
            action: action
        ) {
            TVSettingsActionRowLabel(
                title: title,
                value: value,
                valueTint: valueTint,
                isEnabled: true
            )
        }
    }

    func playbackSettingsLink<Destination: View>(
        title: String,
        value: String,
        valueTint: Color = .secondary,
        accessibilityIdentifier: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        TVSettingsFocusableNavigationControl(
            accessibilityLabel: title,
            accessibilityValue: value,
            accessibilityIdentifier: accessibilityIdentifier,
            destination: {
                screenContainer {
                    destination()
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        ) {
            TVSettingsActionRowLabel(
                title: title,
                value: value,
                valueTint: valueTint,
                isEnabled: true
            )
        }
    }

    var playbackSettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Playback & Display",
            title: "Playback Settings",
            description: "Adjust autoplay, playback mode, and display options.",
            symbolName: "play.rectangle.on.rectangle.fill",
            accent: Color.cyan,
            secondaryAccent: Color.blue,
            summary: playbackHeroSummary
        ) {
            TVSettingsCard {
                TVSettingsSectionBlock(
                    title: "Playback Behavior"
                ) {
                    VStack(spacing: 14) {
                        // Autoplay is now chosen in a subpage, matching the interaction of the other entries.

                        playbackSettingsLink(
                            title: "Autoplay",
                            value: playbackAutoPlaySummary,
                            valueTint: playbackSettings.autoPlayEnabled ? .green : .secondary,
                            accessibilityIdentifier: "settings.playback.autoPlay.link"
                        ) {
                            playbackAutoPlaySettingsView
                        }

                        playbackSettingsLink(
                            title: "Autoplay Interval",
                            value: playbackIntervalSummary,
                            accessibilityIdentifier: "settings.playback.interval.link"
                        ) {
                            playbackIntervalSettingsView
                        }

                        playbackSettingsLink(
                            title: "Default Playback Mode",
                            value: playbackModeSummary,
                            valueTint: playbackSettings.defaultPlaybackMode == .filtered ? .cyan : .secondary,
                            accessibilityIdentifier: "settings.playback.mode.link"
                        ) {
                            playbackDefaultModeSettingsView
                        }

                        playbackSettingsLink(
                            title: "Display Mode",
                            value: playbackDisplayModeSummary,
                            valueTint: playbackSettings.displayMode == .singlePhoto ? .cyan : .secondary,
                            accessibilityIdentifier: "settings.playback.displayMode.link"
                        ) {
                            playbackDisplayModeSettingsView
                        }

                        if playbackSettings.defaultPlaybackMode == .filtered {
                            playbackActionButton(
                                title: "Edit Filters",
                                value: filterSummaryText,
                                valueTint: .secondary,
                                accessibilityIdentifier: "settings.playback.filterConfig.button",
                                action: onOpenFilterEditor
                            )

                            if isFilterSelectionEmpty {
                                TVSettingsStatusBanner(
                                    text: "Filtered Playback is on, but no filters are configured yet.",
                                    tint: .red
                                )
                            }
                        }
                    }
                }

                Divider()

                TVSettingsSectionBlock(
                    title: "Display Items"
                ) {
                    VStack(spacing: 14) {
                        playbackSettingsLink(
                            title: "Display Items",
                            value: playbackDisplaySummary,
                            accessibilityIdentifier: "settings.playback.display.link"
                        ) {
                            playbackDisplaySettingsView
                        }
                    }
                }
            }
        }
    }

    var playbackAutoPlaySettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Playback & Display",
            title: "Autoplay",
            description: "Choose whether to advance automatically to the next photo.",
            symbolName: "play.circle.fill",
            accent: Color.cyan,
            secondaryAccent: Color.blue,
            summary: LocalizedText.format("Current: %@", playbackAutoPlaySummary)
        ) {
            TVSettingsCard {
                TVSettingsSectionBlock(
                    title: "Choose an option"
                ) {
                    VStack(spacing: 14) {
                        TVSettingsChoiceButton(
                            title: "Turn On Autoplay",
                            isSelected: playbackSettings.autoPlayEnabled,
                            accessibilityIdentifier: "settings.playback.autoPlay.on.button",
                            action: {
                                // The shared layer provides a toggle closure, so check
                                // the current value before deciding whether to call it.

                                if !playbackSettings.autoPlayEnabled {
                                    onToggleAutoPlay()
                                }
                            }
                        )
                        .focused($focusedPlaybackBinaryChoice, equals: .primary)
                        .appTVOnMoveCommand { direction in
                            handlePlaybackBinaryChoiceMove(direction, from: .primary)
                        }

                        TVSettingsChoiceButton(
                            title: "Turn Off Autoplay",
                            isSelected: !playbackSettings.autoPlayEnabled,
                            accessibilityIdentifier: "settings.playback.autoPlay.off.button",
                            action: {
                                if playbackSettings.autoPlayEnabled {
                                    onToggleAutoPlay()
                                }
                            }
                        )
                        .focused($focusedPlaybackBinaryChoice, equals: .secondary)
                        .appTVOnMoveCommand { direction in
                            handlePlaybackBinaryChoiceMove(direction, from: .secondary)
                        }
                    }
                }
            }
        }
        .appTVFocusScope(
            playbackBinaryChoiceFocusScope,
            focused: $focusedPlaybackBinaryChoice,
            default: .primary,
            priority: .userInitiated
        )
        .onAppear {
            DispatchQueue.main.async {
                focusedPlaybackBinaryChoice = .primary
            }
        }
    }

    var playbackIntervalSettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Playback & Display",
            title: "Autoplay Interval",
            description: "Choose the autoplay interval.",
            symbolName: "timer",
            accent: Color.cyan,
            secondaryAccent: Color.blue,
            summary: LocalizedText.format("Current: %@", playbackIntervalSummary)
        ) {
            TVSettingsCard {
                TVSettingsSectionBlock(
                    title: "Choose Interval"
                ) {
                    VStack(spacing: 14) {
                        ForEach(intervalOptions, id: \.self) { seconds in
                            TVSettingsChoiceButton(
                                title: LocalizedText.format("%lld sec", Int64(seconds)),
                                isSelected: playbackSettings.intervalSeconds == seconds,
                                accessibilityIdentifier: "settings.playback.interval.\(Int(seconds)).button",
                                action: {
                                    onSelectInterval(seconds)
                                }
                            )
                            .focused($focusedPlaybackIntervalSeconds, equals: seconds)
                        }
                    }
                }
            }
        }
        .appTVFocusScope(
            playbackIntervalFocusScope,
            focused: $focusedPlaybackIntervalSeconds,
            default: intervalOptions.first ?? 5,
            priority: .userInitiated
        )
        .onAppear {
            DispatchQueue.main.async {
                // The interval page has many options, so explicitly set initial focus to
                // the first one instead of leaving it in the navigation transition state.

                focusedPlaybackIntervalSeconds = intervalOptions.first
            }
        }
    }

    var playbackDefaultModeSettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Playback & Display",
            title: "Default Playback Mode",
            description: "Choose whether to start in random or filtered playback.",
            symbolName: "play.square.stack.fill",
            accent: Color.cyan,
            secondaryAccent: Color.blue,
            summary: LocalizedText.format("Current: %@", playbackModeSummary)
        ) {
            TVSettingsCard {
                TVSettingsSectionBlock(
                    title: "Choose Mode"
                ) {
                    VStack(spacing: 14) {
                        TVSettingsChoiceButton(
                            title: "Random Playback",
                            isSelected: playbackSettings.defaultPlaybackMode == .random,
                            accessibilityIdentifier: "settings.playback.mode.random.button",
                            action: {
                                onSelectDefaultPlaybackMode(.random)
                            }
                        )

                        TVSettingsChoiceButton(
                            title: "Filtered Playback",
                            isSelected: playbackSettings.defaultPlaybackMode == .filtered,
                            accessibilityIdentifier: "settings.playback.mode.filtered.button",
                            action: {
                                onSelectDefaultPlaybackMode(.filtered)
                            }
                        )
                    }

                }
            }
        }
        .alert("Can't Switch to Filtered Playback", isPresented: $showFilterModeBlockedAlert) {
            Button("Set Up Filters", role: .destructive) {
                onOpenFilterEditor()
            }
            Button("Cancel", role: .cancel) {
                onCancelFilterModeBlockedAlert()
            }
        } message: {
            Text("No filters are set. Choose albums or people first.")
        }
    }

    var playbackDisplayModeSettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Playback & Display",
            title: "Display Mode",
            description: "Choose whether the slideshow uses Smart Fill or Single Photo Mode.",
            symbolName: "rectangle.3.group.fill",
            accent: Color.cyan,
            secondaryAccent: Color.blue,
            summary: LocalizedText.format("Current: %@", playbackDisplayModeSummary)
        ) {
            TVSettingsCard {
                TVSettingsSectionBlock(
                    title: "Choose a Display Mode"
                ) {
                    VStack(spacing: 14) {
                        TVSettingsChoiceButton(
                            title: "Smart Fill",
                            isSelected: playbackSettings.displayMode == .smartFill,
                            accessibilityIdentifier: "settings.playback.displayMode.smartFill.button",
                            action: {
                                onSelectPlaybackDisplayMode(.smartFill)
                            }
                        )
                        .focused($focusedPlaybackBinaryChoice, equals: .primary)
                        .appTVOnMoveCommand { direction in
                            handlePlaybackBinaryChoiceMove(direction, from: .primary)
                        }

                        TVSettingsChoiceButton(
                            title: "Single Photo Mode",
                            isSelected: playbackSettings.displayMode == .singlePhoto,
                            accessibilityIdentifier: "settings.playback.displayMode.singlePhoto.button",
                            action: {
                                onSelectPlaybackDisplayMode(.singlePhoto)
                            }
                        )
                        .focused($focusedPlaybackBinaryChoice, equals: .secondary)
                        .appTVOnMoveCommand { direction in
                            handlePlaybackBinaryChoiceMove(direction, from: .secondary)
                        }
                    }
                }
            }
        }
        .appTVFocusScope(
            playbackBinaryChoiceFocusScope,
            focused: $focusedPlaybackBinaryChoice,
            default: .primary,
            priority: .userInitiated
        )
        .onAppear {
            DispatchQueue.main.async {
                focusedPlaybackBinaryChoice = .primary
            }
        }
    }

    var playbackDisplaySettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Playback & Display",
            title: "Display Items",
            description: "Manage the information overlays shown on the playback screen.",
            symbolName: "text.below.photo",
            accent: Color.cyan,
            secondaryAccent: Color.blue,
            summary: playbackDisplaySummary
        ) {
            TVSettingsCard {
                TVSettingsSectionBlock(
                    title: "Information Overlays"
                ) {
                    VStack(spacing: 14) {
                        playbackSettingsLink(
                            title: "EXIF Info",
                            value: playbackExifSummary,
                            valueTint: playbackSettings.showExif ? .green : .secondary,
                            accessibilityIdentifier: "settings.playback.showExif.link"
                        ) {
                            playbackExifSettingsView
                        }

                        if PlatformCompat.playbackDebugPanelEnabled {
                            playbackSettingsLink(
                                title: "Debug Panel",
                                value: playbackDebugSummary,
                                valueTint: playbackSettings.showDebugOverlay ? .green : .secondary,
                                accessibilityIdentifier: "settings.playback.showDebug.link"
                            ) {
                                playbackDebugOverlaySettingsView
                            }
                        }
                    }
                }
            }
        }
    }

    var playbackExifSettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Playback & Display",
            title: "EXIF Info",
            description: "Choose whether to show photo metadata.",
            symbolName: "camera.aperture",
            accent: Color.cyan,
            secondaryAccent: Color.blue,
            summary: LocalizedText.format("Current: %@", playbackExifSummary)
        ) {
            TVSettingsCard {
                TVSettingsSectionBlock(
                    title: "Choose visibility"
                ) {
                    VStack(spacing: 14) {
                        TVSettingsChoiceButton(
                            title: "Show EXIF Info",
                            isSelected: playbackSettings.showExif,
                            accessibilityIdentifier: "settings.playback.showExif.on.button",
                            action: {
                                if !playbackSettings.showExif {
                                    onToggleShowExif()
                                }
                            }
                        )
                        .focused($focusedPlaybackBinaryChoice, equals: .primary)
                        .appTVOnMoveCommand { direction in
                            handlePlaybackBinaryChoiceMove(direction, from: .primary)
                        }

                        TVSettingsChoiceButton(
                            title: "Hide EXIF Info",
                            isSelected: !playbackSettings.showExif,
                            accessibilityIdentifier: "settings.playback.showExif.off.button",
                            action: {
                                if playbackSettings.showExif {
                                    onToggleShowExif()
                                }
                            }
                        )
                        .focused($focusedPlaybackBinaryChoice, equals: .secondary)
                        .appTVOnMoveCommand { direction in
                            handlePlaybackBinaryChoiceMove(direction, from: .secondary)
                        }
                    }
                }
            }
        }
        .appTVFocusScope(
            playbackBinaryChoiceFocusScope,
            focused: $focusedPlaybackBinaryChoice,
            default: .primary,
            priority: .userInitiated
        )
        .onAppear {
            DispatchQueue.main.async {
                focusedPlaybackBinaryChoice = .primary
            }
        }
    }

    var playbackDebugOverlaySettingsView: some View {
        TVSettingsPageScaffold(
            eyebrow: "Playback & Display",
            title: "Debug Panel",
            description: "Choose whether to show debug information.",
            symbolName: "ladybug.fill",
            accent: Color.cyan,
            secondaryAccent: Color.blue,
            summary: LocalizedText.format("Current: %@", playbackDebugSummary)
        ) {
            TVSettingsCard {
                TVSettingsSectionBlock(
                    title: "Choose visibility"
                ) {
                    VStack(spacing: 14) {
                        TVSettingsChoiceButton(
                            title: "Show Debug Panel",
                            isSelected: playbackSettings.showDebugOverlay,
                            accessibilityIdentifier: "settings.playback.showDebug.on.button",
                            action: {
                                if !playbackSettings.showDebugOverlay {
                                    onToggleShowDebugOverlay()
                                }
                            }
                        )
                        .focused($focusedPlaybackBinaryChoice, equals: .primary)
                        .appTVOnMoveCommand { direction in
                            handlePlaybackBinaryChoiceMove(direction, from: .primary)
                        }

                        TVSettingsChoiceButton(
                            title: "Hide Debug Panel",
                            isSelected: !playbackSettings.showDebugOverlay,
                            accessibilityIdentifier: "settings.playback.showDebug.off.button",
                            action: {
                                if playbackSettings.showDebugOverlay {
                                    onToggleShowDebugOverlay()
                                }
                            }
                        )
                        .focused($focusedPlaybackBinaryChoice, equals: .secondary)
                        .appTVOnMoveCommand { direction in
                            handlePlaybackBinaryChoiceMove(direction, from: .secondary)
                        }
                    }
                }
            }
        }
        .appTVFocusScope(
            playbackBinaryChoiceFocusScope,
            focused: $focusedPlaybackBinaryChoice,
            default: .primary,
            priority: .userInitiated
        )
        .onAppear {
            DispatchQueue.main.async {
                focusedPlaybackBinaryChoice = .primary
            }
        }
    }

    func handlePlaybackBinaryChoiceMove(
        _ direction: AppMoveDirection,
        from current: PlaybackBinaryChoiceFocusTarget
    ) {
        let target: PlaybackBinaryChoiceFocusTarget?

        switch (current, direction) {
        case (.primary, .down):
            target = .secondary
        case (.secondary, .up):
            target = .primary
        default:
            target = nil
        }

        guard let target else { return }

        DispatchQueue.main.async {
            focusedPlaybackBinaryChoice = target
        }
    }
    var playbackHeroSummary: String {
        let autoPlayLabel =
            playbackSettings.autoPlayEnabled
            ? String(localized: "Autoplay On")
            : String(localized: "Autoplay Off")
        let modeLabel =
            playbackSettings.defaultPlaybackMode == .filtered
            ? String(localized: "Filtered by Default")
            : String(localized: "Shuffle by Default")
        return LocalizedText.format("%@ · %@", autoPlayLabel, modeLabel)
    }

    var playbackAutoPlaySummary: String {
        playbackSettings.autoPlayEnabled ? String(localized: "Turned on") : String(localized: "Turned off")
    }

    var playbackIntervalSummary: String {
        LocalizedText.format("%lld sec", Int64(playbackSettings.intervalSeconds))
    }

    var playbackModeSummary: String {
        playbackSettings.defaultPlaybackMode == .filtered
            ? String(localized: "Filtered Playback")
            : String(localized: "Random Playback")
    }

    var playbackDisplayModeSummary: String {
        playbackSettings.displayMode == .singlePhoto
            ? String(localized: "Single Photo Mode")
            : String(localized: "Smart Fill")
    }

    var playbackDisplaySummary: String {
        let exifLabel =
            playbackSettings.showExif
            ? String(localized: "EXIF On")
            : String(localized: "EXIF Off")
        guard PlatformCompat.playbackDebugPanelEnabled else { return exifLabel }
        let debugLabel =
            playbackSettings.showDebugOverlay
            ? String(localized: "Debug On")
            : String(localized: "Debug Off")
        return LocalizedText.format("%@ · %@", exifLabel, debugLabel)
    }

    var playbackExifSummary: String {
        playbackSettings.showExif ? String(localized: "Shown") : String(localized: "Hidden")
    }

    var playbackDebugSummary: String {
        playbackSettings.showDebugOverlay ? String(localized: "Shown") : String(localized: "Hidden")
    }
}
