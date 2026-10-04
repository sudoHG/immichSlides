//
//  SlideshowControlBarView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/16.
//

import Foundation
import SwiftUI

// A full-sentence template decides where the keycap goes in each language, instead of forcing phrases together in
// Chinese word order.
struct LocalizedKeycapInstruction {
    let leadingText: String
    let keycapLabel: String
    let trailingText: String
    let accessibilityLabel: String

    init(template: String, keycapLabel: String) {
        self.keycapLabel = keycapLabel

        let placeholderRange = ["%1$@", "%@"].compactMap { template.range(of: $0) }.first
        guard let placeholderRange else {
            leadingText = template.trimmingCharacters(in: .whitespacesAndNewlines)
            trailingText = ""
            accessibilityLabel = [template, keycapLabel]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return
        }

        leadingText = String(template[..<placeholderRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        trailingText = String(template[placeholderRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        accessibilityLabel = template.replacingCharacters(
            in: placeholderRange,
            with: keycapLabel
        )
    }
}

// Holds only the iOS tutorial text; the control bar does not know the higher-level business logic.

struct IOSSlideshowEntryHintContent {

    let title: String
    let actionInstruction: LocalizedKeycapInstruction

    init(title: String, actionTemplate: String, actionKeyLabel: String) {
        self.title = title
        actionInstruction = LocalizedKeycapInstruction(
            template: actionTemplate,
            keycapLabel: actionKeyLabel
        )
    }

    static let empty = IOSSlideshowEntryHintContent(
        title: "",
        actionTemplate: "",
        actionKeyLabel: ""
    )
}

// One-time iOS tutorial bubble: a single Shape; tapping the bubble itself closes it, not pressing the down key.

private struct IOSSlideshowEntryHintBubble: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var measuredIdealContentWidth: CGFloat = 0
    let content: IOSSlideshowEntryHintContent
    let tailCenterX: CGFloat
    let onTap: (() -> Void)?

    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    // Size the font per device first, then let Dynamic Type enlarge it, instead of reusing tvOS's fixed large sizes.

    private var bubbleCornerRadius: CGFloat { isCompactHeight ? 14 : 18 }
    private var bubbleTailWidth: CGFloat { isCompactHeight ? 18 : (isCompactWidth ? 20 : 24) }
    private var bubbleTailHeight: CGFloat { isCompactHeight ? 11 : 14 }

    private var bubbleContentSpacing: CGFloat {
        isCompactHeight ? 8 : 10
    }

    private var bubbleHorizontalPadding: CGFloat {
        if isCompactHeight { return 10 }
        return isCompactWidth ? 12 : 14
    }

    private var bubbleTopPadding: CGFloat {
        isCompactHeight ? 12 : 14
    }

    private var bubbleBottomPadding: CGFloat {
        isCompactHeight ? 18 : 20
    }

    private var titleFont: Font {
        if dynamicTypeSize.isAccessibilitySize {
            if isCompactHeight { return .caption }
            return isCompactWidth ? .footnote : .headline
        }
        if isCompactHeight { return .callout }
        return isCompactWidth ? .headline : .title3
    }

    private var bubbleShadowRadius: CGFloat {
        isCompactHeight ? 10 : 12
    }

    private var bubbleShadowYOffset: CGFloat {
        isCompactHeight ? 4 : 6
    }

    var body: some View {
        let bubbleShape = IOSSlideshowEntryHintBubbleShape(
            cornerRadius: bubbleCornerRadius,
            tailWidth: bubbleTailWidth,
            tailHeight: bubbleTailHeight,
            tailCenterX: tailCenterX
        )

        VStack(alignment: .leading, spacing: bubbleContentSpacing) {
            Text(content.title)
                .font(titleFont)
                .fontWeight(.semibold)
                .foregroundStyle(Color.white.opacity(0.98))
                .multilineTextAlignment(.leading)
                // Single-line title: size to the text first, then use minimumScaleFactor in narrow layouts; never wrap
                // to multiple lines.

                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.78 : 0.84)
                .accessibilityIdentifier("slideshow.entryHint.title")

            IOSSlideshowEntryHintActionRow(content: content)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: IOSSlideshowEntryHintIdealContentWidthPreferenceKey.self,
                        value: proxy.size.width
                    )
            }
        }
        // Measure the longest line for the width first and cap it only when it exceeds the limit, so there is no empty
        // space on the right.

        .frame(width: resolvedBubbleContentWidth, alignment: .leading)
        .padding(.horizontal, bubbleHorizontalPadding)
        // The bottom padding includes the tail height, because the body and the tail are one Shape.
        .padding(.top, bubbleTopPadding)
        .padding(.bottom, bubbleBottomPadding)
        .background {
            bubbleShape
                .fill(.ultraThinMaterial)
        }
        .overlay {
            bubbleShape
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.20), radius: bubbleShadowRadius, x: 0, y: bubbleShadowYOffset)
        // Cap the hint bubble's font size at accessibility1, so the hint does not grow and cover the control bar.

        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // Do not lock the horizontal size; tight layouts can still negotiate, so it does not end up only wrapping or
        // truncating.

        .fixedSize(horizontal: false, vertical: true)
        // The tap is attached to the whole bubble, because the close gesture is tapping the bubble.

        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .onPreferenceChange(IOSSlideshowEntryHintIdealContentWidthPreferenceKey.self) { newWidth in
            guard abs(newWidth - measuredIdealContentWidth) > 0.5 else { return }
            measuredIdealContentWidth = newWidth
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow.entryHint.banner")
    }

    private var resolvedBubbleContentWidth: CGFloat? {
        guard measuredIdealContentWidth > 0 else { return nil }
        return min(measuredIdealContentWidth, bubbleMaxContentWidth)
    }

    private var bubbleMaxContentWidth: CGFloat {
        // maxWidth is only an upper limit; the final width comes from the measured content width.

        if dynamicTypeSize.isAccessibilitySize {
            if isCompactHeight { return 294 }
            return isCompactWidth ? 352 : 368
        }
        if isCompactHeight { return 264 }
        return isCompactWidth ? 320 : 348
    }
}

// Report the longest line's width through a PreferenceKey, so the bubble locks to the real content width.

private struct IOSSlideshowEntryHintIdealContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// The second-line action sentence is its own subview, so it does not mix with the main sentence.

private struct IOSSlideshowEntryHintActionRow: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let content: IOSSlideshowEntryHintContent

    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    private var accessibilityActionLabel: String {
        content.actionInstruction.accessibilityLabel
    }

    var body: some View {
        inlineActionRow
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: accessibilityActionLabel))
            .accessibilityIdentifier("slideshow.entryHint.action")
    }

    private var inlineActionRow: some View {
        HStack(alignment: .center, spacing: actionItemSpacing) {
            Text(content.actionInstruction.leadingText)
                .font(actionFont)
                .fontWeight(.medium)
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.90 : 0.84)
                .accessibilityIdentifier("slideshow.entryHint.actionPrefix")

            IOSSlideshowEntryHintKeycap(label: content.actionInstruction.keycapLabel)

            Text(content.actionInstruction.trailingText)
                .font(actionFont)
                .fontWeight(.medium)
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.88 : 0.82)
                .accessibilityIdentifier("slideshow.entryHint.actionSuffix")
        }
        .lineLimit(1)
        .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.90 : 0.82)
    }

    private var actionFont: Font {
        if dynamicTypeSize.isAccessibilitySize {
            if isCompactHeight { return .caption2 }
            return isCompactWidth ? .caption : .footnote
        }
        if isCompactHeight { return .caption }
        return isCompactWidth ? .footnote : .callout
    }

    private var actionItemSpacing: CGFloat {
        isCompactHeight ? 5 : 7
    }
}

// The iOS keycap copies the tvOS look, but the text says "bubble" because it is closed by tapping.

private struct IOSSlideshowEntryHintKeycap: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let label: String

    private var isCompactWidth: Bool { horizontalSizeClass == .compact }
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    var body: some View {
        HStack(alignment: .center, spacing: keycapInnerSpacing) {
            Image(systemName: "hand.tap.fill")
                .font(keycapIconFont)
                .fontWeight(.bold)
                .foregroundStyle(Color.white.opacity(0.96))

            Text(label)
                .font(keycapTextFont)
                .fontWeight(.semibold)
                .foregroundStyle(Color.white.opacity(0.96))
                .lineLimit(1)
                .minimumScaleFactor(0.92)
        }
        .padding(.horizontal, keycapHorizontalPadding)
        .padding(.vertical, keycapVerticalPadding)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: keycapCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: keycapCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityIdentifier("slideshow.entryHint.keycap")
    }

    private var keycapTextFont: Font {
        if isCompactHeight { return .caption }
        if isCompactWidth { return .footnote }
        return .callout
    }

    private var keycapIconFont: Font {
        if isCompactHeight { return .caption2 }
        return isCompactWidth ? .caption : .footnote
    }

    private var keycapInnerSpacing: CGFloat {
        isCompactHeight ? 4 : 5
    }

    private var keycapHorizontalPadding: CGFloat {
        isCompactHeight ? 8 : 9
    }

    private var keycapVerticalPadding: CGFloat {
        isCompactHeight ? 4 : 5
    }

    private var keycapCornerRadius: CGFloat {
        isCompactHeight ? 7 : 8
    }
}

// One Shape draws both the body and the tail, instead of crudely joining a rounded rectangle and a small square.

private struct IOSSlideshowEntryHintBubbleShape: Shape {
    let cornerRadius: CGFloat
    let tailWidth: CGFloat
    let tailHeight: CGFloat
    let tailCenterX: CGFloat

    func path(in rect: CGRect) -> Path {
        // The body height excludes the tail, so subtract tailHeight first.
        let bodyMaxY = rect.maxY - tailHeight
        let clampedCornerRadius = min(cornerRadius, (bodyMaxY - rect.minY) / 2, rect.width / 2)

        // Keep the tail center clear of the left/right rounded corners so the curves do not squeeze each other.
        let minTailCenterX = rect.minX + clampedCornerRadius + tailWidth * 0.9
        let maxTailCenterX = rect.maxX - clampedCornerRadius - tailWidth * 0.9
        let resolvedTailCenterX = min(
            max(rect.minX + tailCenterX, minTailCenterX),
            maxTailCenterX
        )
        let tailLeftX = resolvedTailCenterX - tailWidth / 2
        let tailRightX = resolvedTailCenterX + tailWidth / 2
        let tailTip = CGPoint(x: resolvedTailCenterX, y: rect.maxY)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + clampedCornerRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - clampedCornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + clampedCornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bodyMaxY - clampedCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - clampedCornerRadius, y: bodyMaxY),
            control: CGPoint(x: rect.maxX, y: bodyMaxY)
        )
        path.addLine(to: CGPoint(x: tailRightX, y: bodyMaxY))
        path.addQuadCurve(
            to: tailTip,
            control: CGPoint(
                x: resolvedTailCenterX + tailWidth * 0.22,
                y: bodyMaxY + tailHeight * 0.58
            )
        )
        path.addQuadCurve(
            to: CGPoint(x: tailLeftX, y: bodyMaxY),
            control: CGPoint(
                x: resolvedTailCenterX - tailWidth * 0.22,
                y: bodyMaxY + tailHeight * 0.58
            )
        )
        path.addLine(to: CGPoint(x: rect.minX + clampedCornerRadius, y: bodyMaxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bodyMaxY - clampedCornerRadius),
            control: CGPoint(x: rect.minX, y: bodyMaxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + clampedCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + clampedCornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

struct SlideshowControlBarView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var measuredEntryHintBubbleHeight: CGFloat = 0

    @Binding var isAutoPlay: Bool

    let isPreviousEnabled: Bool

    var onPrevious: () -> Void
    var onNext: () -> Void
    var onPlayPause: () -> Void
    var onSettings: () -> Void  // Tutorial-hint params have defaults, so old call sites need not all change at once.

    let showsEntryHintBubble: Bool
    let entryHintContent: IOSSlideshowEntryHintContent

    let onEntryHintTap: (() -> Void)?

    @Namespace private var glassNamespace
    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    private struct ControlButton {
        let id: String
        let icon: String
        let isEnabled: Bool
        let action: () -> Void
    }
    // The play/pause icon changes, so the button list is a computed property rather than a stored copy.

    private var controlButtons: [ControlButton] {
        [
            ControlButton(id: "settings", icon: "gearshape.fill", isEnabled: true, action: onSettings),
            ControlButton(
                id: "previous", icon: "arrowshape.left.fill", isEnabled: isPreviousEnabled, action: onPrevious),
            ControlButton(
                id: "playPause", icon: isAutoPlay ? "pause.fill" : "play.fill", isEnabled: true, action: onPlayPause),
            ControlButton(id: "next", icon: "arrowshape.right.fill", isEnabled: true, action: onNext)
        ]
    }

    private var entryHintHorizontalOffset: CGFloat {
        if isCompactHeight { return -10 }

        return isCompact ? -12 : -8
    }

    private var entryHintTailGapToSettingsButton: CGFloat {
        2
    }

    private var fallbackEntryHintVerticalOffset: CGFloat {
        let baseOffset: CGFloat = {
            if isCompactHeight { return -84 }

            return isCompact ? -91 : -104
        }()
        if dynamicTypeSize.isAccessibilitySize {
            // For accessibility sizes, raise it only slightly: enough that body text does not touch the buttons, but
            // not so much that it visibly floats again.

            if isCompactHeight { return baseOffset - 2 }
            // Portrait fallback offsets differ for iPhone/iPad: on iPhone it sits against the gear; with large iPad
            // regular fonts it moves a bit more.

            return baseOffset - (isCompact ? 12 : 22)
        }
        return baseOffset
    }

    private func entryHintVerticalOffset(buttonTopInset: CGFloat) -> CGFloat {
        guard measuredEntryHintBubbleHeight > 0 else {
            return fallbackEntryHintVerticalOffset
        }
        // Bubble height changes with Dynamic Type/text, so use the measured height to put the tail just above the
        // settings button.

        return buttonTopInset - measuredEntryHintBubbleHeight - entryHintTailGapToSettingsButton
    }

    private func entryHintTailCenterX(for buttonSize: CGFloat) -> CGFloat {
        buttonSize / 2 - entryHintHorizontalOffset
    }

    private var legacyControlBarEntryHintLeadingOffset: CGFloat {
        legacyControlBarHorizontalPadding + entryHintHorizontalOffset
    }

    private var glassControlBarEntryHintLeadingOffset: CGFloat {
        1 + glassControlBarSpacing + entryHintHorizontalOffset
    }

    private var legacyControlBarHorizontalPadding: CGFloat {
        isCompactHeight ? 10 : (isCompact ? 12 : 40)
    }

    private var glassControlBarSpacing: CGFloat {
        isCompactHeight ? 10 : 20
    }

    init(
        isAutoPlay: Binding<Bool>,
        isPreviousEnabled: Bool = true,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onPlayPause: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        showsEntryHintBubble: Bool = false,
        entryHintContent: IOSSlideshowEntryHintContent = .empty,
        onEntryHintTap: (() -> Void)? = nil
    ) {
        self._isAutoPlay = isAutoPlay
        self.isPreviousEnabled = isPreviousEnabled
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onPlayPause = onPlayPause
        self.onSettings = onSettings
        self.showsEntryHintBubble = showsEntryHintBubble
        self.entryHintContent = entryHintContent
        self.onEntryHintTap = onEntryHintTap
    }

    struct ControlButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            ZStack {
                configuration.label
                    .scaleEffect(configuration.isPressed ? 0.85 : 1.0)
                    .opacity(configuration.isPressed ? 0.7 : 1.0)
            }
            .contentShape(Rectangle())  // The hit area does not scale when pressed.
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
        }
    }

    var body: some View {
        if #available(iOS 26.0, tvOS 26.0, *) {
            let buttonSize: CGFloat = isCompactHeight ? 46 : 60
            let iconSize: CGFloat = isCompactHeight ? 19 : 25
            let spacing = glassControlBarSpacing
            GlassEffectContainer(spacing: 20) {
                HStack(spacing: spacing) {
                    Color.clear
                        .frame(width: 1, height: buttonSize)
                        .glassEffect()
                        .glassEffectUnion(id: "buttons", namespace: glassNamespace)
                    ForEach(controlButtons, id: \.id) { button in
                        Button(action: button.action) {
                            Image(systemName: button.icon)
                                .frame(width: buttonSize, height: buttonSize)
                                .font(.system(size: iconSize, weight: .bold))
                                .glassEffect()
                                .glassEffectUnion(id: "buttons", namespace: glassNamespace)

                        }
                        .buttonStyle(ControlButtonStyle())
                        .disabled(!button.isEnabled)
                        .opacity(button.isEnabled ? 1 : 0.42)
                        .accessibilityIdentifier("slideshow.control.\(button.id).button")
                        .accessibilityValue(
                            button.id == "playPause"
                                ? Text(LocalizedStringKey(isAutoPlay ? "pause" : "play"))

                                : Text(verbatim: "")
                        )
                    }
                    Color.clear
                        .frame(width: 1, height: buttonSize)
                        .glassEffect()
                        .glassEffectUnion(id: "buttons", namespace: glassNamespace)
                }
            }
            .overlay(alignment: .topLeading) {
                if showsEntryHintBubble {
                    IOSSlideshowEntryHintBubble(
                        content: entryHintContent,
                        tailCenterX: entryHintTailCenterX(for: buttonSize),
                        onTap: onEntryHintTap
                    )
                    .measureEntryHintBubbleHeight()
                    .offset(
                        x: glassControlBarEntryHintLeadingOffset,
                        y: entryHintVerticalOffset(buttonTopInset: 0)
                    )
                    .allowsHitTesting(onEntryHintTap != nil)
                }
            }
            .onPreferenceChange(IOSSlideshowEntryHintBubbleHeightPreferenceKey.self) { newHeight in
                guard abs(newHeight - measuredEntryHintBubbleHeight) > 0.5 else { return }
                measuredEntryHintBubbleHeight = newHeight
            }
        } else {
            let buttonSize: CGFloat = isCompactHeight ? 44 : (isCompact ? 56 : 90)
            let iconSize: CGFloat = isCompactHeight ? 20 : (isCompact ? 24 : 40)
            let spacing: CGFloat = isCompactHeight ? 8 : (isCompact ? 12 : 40)
            let horizontalPadding = legacyControlBarHorizontalPadding
            let verticalPadding: CGFloat = isCompactHeight ? 8 : 10
            let cornerRadius: CGFloat = isCompactHeight ? 28 : 80
            let shadowRadius: CGFloat = isCompactHeight ? 18 : 50
            HStack(spacing: spacing) {
                ForEach(controlButtons, id: \.id) { button in
                    Button(action: button.action) {
                        Image(systemName: button.icon)
                            .frame(width: buttonSize, height: buttonSize)
                            .font(.system(size: iconSize, weight: .bold))

                    }
                    .buttonStyle(ControlButtonStyle())
                    .disabled(!button.isEnabled)
                    .opacity(button.isEnabled ? 1 : 0.42)
                    .accessibilityIdentifier("slideshow.control.\(button.id).button")
                    .accessibilityValue(
                        button.id == "playPause"
                            ? Text(LocalizedStringKey(isAutoPlay ? "pause" : "play"))
                            // An empty accessibility value uses verbatim, so no empty localization key is generated.

                            : Text(verbatim: "")
                    )
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(.ultraThinMaterial)
            .cornerRadius(cornerRadius)
            .shadow(color: .black.opacity(0.2), radius: shadowRadius)
            .overlay(alignment: .topLeading) {
                if showsEntryHintBubble {
                    IOSSlideshowEntryHintBubble(
                        content: entryHintContent,
                        tailCenterX: entryHintTailCenterX(for: buttonSize),
                        onTap: onEntryHintTap
                    )
                    .measureEntryHintBubbleHeight()
                    .offset(
                        x: legacyControlBarEntryHintLeadingOffset,
                        y: entryHintVerticalOffset(buttonTopInset: verticalPadding)
                    )
                    .allowsHitTesting(onEntryHintTap != nil)
                }
            }
            .onPreferenceChange(IOSSlideshowEntryHintBubbleHeightPreferenceKey.self) { newHeight in
                guard abs(newHeight - measuredEntryHintBubbleHeight) > 0.5 else { return }
                measuredEntryHintBubbleHeight = newHeight
            }
        }
    }
}

private struct IOSSlideshowEntryHintBubbleHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    func measureEntryHintBubbleHeight() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: IOSSlideshowEntryHintBubbleHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
    }
}

#Preview {
    SlideshowControlBarView(
        isAutoPlay: .constant(true),
        onPrevious: {},
        onNext: {},
        onPlayPause: {},
        onSettings: {},
        showsEntryHintBubble: true,
        entryHintContent: IOSSlideshowEntryHintContent(
            title: "Adjust photo range and speed here",
            actionTemplate: "Tap %@ to hide this tip",
            actionKeyLabel: "bubble"
        ),
        onEntryHintTap: {}
    )
    .padding()
    .background(Color.yellow.opacity(0.5))
}
