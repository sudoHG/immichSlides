import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Collects platform color/style branches, so shared views do not touch iOS-only APIs directly.

enum PlatformCompat {
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Debug-only: true when this process only hosts the unit test bundle, so the app UI must stay idle.
    static var isHostingUnitTests: Bool {
        #if DEBUG
        return isUnitTestHost(
            environment: ProcessInfo.processInfo.environment,
            isXCTestLoaded: NSClassFromString("XCTestCase") != nil
        )
        #else
        return false
        #endif
    }

    #if DEBUG
    /// Some UI tests set XCTestConfigurationFilePath on the launched app to expose probes; only a real host has XCTest loaded.
    static func isUnitTestHost(environment: [String: String], isXCTestLoaded: Bool) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil && isXCTestLoaded
    }
    #endif

    /// UI tests launch the app with UI_TEST_RESET_STATE or an XCTest configuration; release builds never expose probes.
    static var shouldExposeUITestProbes: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["UI_TEST_RESET_STATE"] == "1"
        #else
        return false
        #endif
    }

    /// UI tests set UI_TEST_FORCE_MODE_SELECTION to turn a configured cold launch into an onboarding session; always false in Release.
    static var shouldForceModeSelectionForUITesting: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["UI_TEST_FORCE_MODE_SELECTION"] == "1"
        #else
        return false
        #endif
    }

    /// An empty Info.plist string counts as not configured.
    static func infoPlistString(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Debug config is read only in DEBUG; Release returns nil.
    static func debugInfoPlistString(_ key: String) -> String? {
        #if DEBUG
        return infoPlistString(key)
        #else
        return nil
        #endif
    }

    /// Always false in Release; runtime environment variables take priority over the Debug Info.plist.

    static func debugFeatureEnabled(
        infoPlistKey: String,
        runtimeOverrideKey: String? = nil
    ) -> Bool {
        guard isDebugBuild else { return false }

        if let runtimeOverrideKey,
            let rawOverride = ProcessInfo.processInfo.environment[runtimeOverrideKey]
        {
            let trimmedOverride = rawOverride.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedOverride == "1" {
                return true
            }

            if trimmedOverride == "0" {
                return false
            }
        }

        return debugInfoPlistString(infoPlistKey) == "1"
    }

    /// The settings entry and playback page rendering share one gate, so old persisted state cannot still show the
    /// panel after the entry is hidden.

    static var playbackDebugPanelEnabled: Bool {
        debugFeatureEnabled(
            infoPlistKey: "ENABLE_DEBUG_SETTINGS_ENTRY",
            runtimeOverrideKey: "UI_TEST_ENABLE_DEBUG_SETTINGS_ENTRY"
        )
    }

    /// Not a real user setting and not persisted; it only lets acceptance testing reach the single-photo path from
    /// env.xcconfig.

    static var forceSinglePhotoPlaybackForDebug: Bool {
        debugFeatureEnabled(
            infoPlistKey: "ENABLE_DEBUG_FORCE_SINGLE_PHOTO_PLAYBACK",
            runtimeOverrideKey: "IMMICHSLIDES_DISABLE_SMART_FILL"
        )
    }

    static var systemBackground: Color {
        #if os(iOS)
        return Color(uiColor: .systemBackground)
        #elseif os(tvOS)
        return Color(
            UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(white: 0.10, alpha: 1.0)
                    : UIColor(white: 0.97, alpha: 1.0)
            }
        )
        #else
        return Color.white
        #endif
    }

    static var secondarySystemBackground: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemBackground)
        #elseif os(tvOS)
        return Color(
            UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(white: 0.16, alpha: 1.0)
                    : UIColor(white: 0.93, alpha: 1.0)
            }
        )
        #else
        return Color.gray.opacity(0.12)
        #endif
    }

    static var systemGroupedBackground: Color {
        #if os(iOS)
        return Color(uiColor: .systemGroupedBackground)
        #elseif os(tvOS)
        return Color(
            UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(white: 0.12, alpha: 1.0)
                    : UIColor(white: 0.95, alpha: 1.0)
            }
        )
        #else
        return Color.gray.opacity(0.08)
        #endif
    }

    static var secondarySystemGroupedBackground: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #elseif os(tvOS)
        return Color(
            UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(white: 0.18, alpha: 1.0)
                    : UIColor(white: 0.91, alpha: 1.0)
            }
        )
        #else
        return Color.gray.opacity(0.16)
        #endif
    }

    static var separator: Color {
        #if os(iOS) || os(tvOS)
        return Color(uiColor: .separator)
        #else
        return Color.black.opacity(0.12)
        #endif
    }
    static func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS) || os(tvOS)
        // Disable auto-sleep on the playback page; applies to both iOS and tvOS.

        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

/// Arrow-key semantics live in a shared enum, so tvOS types do not leak into shared code.
enum AppMoveDirection {
    case up
    case down
    case left
    case right
    case other
}

extension View {
    /// tvOS has no navigationBarTitleDisplayMode, so this is a no-op there.
    @ViewBuilder
    func appNavigationBarTitleDisplayModeInline() -> some View {
        #if os(tvOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// tvOS has no statusBar(hidden:); this keeps shared views compiling.
    @ViewBuilder
    func appStatusBarHidden(_ hidden: Bool) -> some View {
        #if os(iOS)
        self.statusBar(hidden: hidden)
        #else
        self
        #endif
    }

    /// tvOS has no insetGrouped, so this falls back to plain.
    @ViewBuilder
    func appListStyleInsetGrouped() -> some View {
        #if os(tvOS)
        self.listStyle(.plain)
        #else
        self.listStyle(.insetGrouped)
        #endif
    }

    /// tvOS has no sidebar, so this falls back to plain.
    @ViewBuilder
    func appListStyleSidebar() -> some View {
        #if os(tvOS)
        self.listStyle(.plain)
        #else
        self.listStyle(.sidebar)
        #endif
    }

    @ViewBuilder
    func appFormTextInputBehavior() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }

    /// When we draw focus ourselves, turn off the system default highlight plate so no extra white glow wraps it.

    @ViewBuilder
    func appTVDisableDefaultFocusEffect(_ disabled: Bool = true) -> some View {
        #if os(tvOS)
        self.focusEffectDisabled(disabled)
        #else
        self
        #endif
    }

    /// Single entry point for tvOS focus outlines.
    @ViewBuilder
    func appTVFocusOutline(
        isFocused: Bool,
        focusedColor: Color,
        focusedLineWidth: CGFloat,
        cornerRadius: CGFloat,
        normalColor: Color = Color.white.opacity(0.25),
        normalLineWidth: CGFloat = 1
    ) -> some View {
        #if os(tvOS)
        self.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    isFocused ? focusedColor : normalColor,
                    lineWidth: isFocused ? focusedLineWidth : normalLineWidth
                )
        )
        #else
        self
        #endif
    }

    /// tvOS disabled state gets stronger contrast so it is visible from a distance.
    @ViewBuilder
    func appTVDisabledEmphasis(_ isEnabled: Bool) -> some View {
        #if os(tvOS)
        self
            .opacity(isEnabled ? 1.0 : 0.45)
            .saturation(isEnabled ? 1.0 : 0.2)
        #else
        self
        #endif
    }

    /// Arrow-key interception only takes effect on tvOS.
    @ViewBuilder
    func appTVOnMoveCommand(_ action: @escaping (AppMoveDirection) -> Void) -> some View {
        #if os(tvOS)
        self.onMoveCommand { direction in
            switch direction {
            case .up:
                action(.up)
            case .down:
                action(.down)
            case .left:
                action(.left)
            case .right:
                action(.right)
            default:
                action(.other)
            }
        }
        #else
        self
        #endif
    }

    /// tvOS focus section; ignored on other platforms.
    @ViewBuilder
    func appTVFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }

    /// tvOS focus scope and default focus; ignored on other platforms.
    @ViewBuilder
    func appTVFocusScope<V: Hashable>(
        _ namespace: Namespace.ID,
        focused: FocusState<V?>.Binding,
        default defaultValue: V,
        priority: DefaultFocusEvaluationPriority = .automatic
    ) -> some View {
        #if os(tvOS)
        self
            .focusScope(namespace)
            // Overlays must use .userInitiated, or tvOS may not land on the declared default focus right away.

            .defaultFocus(focused, defaultValue, priority: priority)
        #else
        self
        #endif
    }
}
