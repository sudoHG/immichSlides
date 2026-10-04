//
//  CoverCardView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/2/5.
//

import SwiftUI
import SDWebImageSwiftUI

private enum CoverCardMetrics {
    static let smallCardWidthPoints: CGFloat = 240
    static let smallCardHeightPoints: CGFloat = 180
    static let smallTitleFontSizePoints: CGFloat = 16
    static let regularTitleFontSizePoints: CGFloat = 21
    static let smallSubtitleFontSizePoints: CGFloat = 13
    static let regularSubtitleFontSizePoints: CGFloat = 18
    static let smallHorizontalInsetPoints: CGFloat = 12
    static let regularHorizontalInsetPoints: CGFloat = 20
    static let smallVerticalInsetPoints: CGFloat = 3
    static let regularVerticalInsetPoints: CGFloat = 5
    static let gradientOpacity: Double = 0.9
    static let gradientHeightFraction: CGFloat = 0.4
    static let titleLineLimit: Int = 2
    static let subtitleLineLimit: Int = 1
    static let textMinimumScaleFactor: CGFloat = 0.85
    static let subtitleOpacity: Double = 0.6
    static let textShadowRadiusPoints: CGFloat = 30
}

struct CoverCardView: View {

    let name: String
    let coverURL: URL
    let assetsCount: Int?
    // Remote thumbnail requests must carry the API Key, otherwise authentication fails.

    let requestContext: [SDWebImageContextOption: Any] = {
        if let modifier = ImmichRequestModifier.create() {
            return [.downloadRequestModifier: modifier]
        }
        return [:]
    }()

    var body: some View {

        GeometryReader { geometry in
            let isSmallCard =
                geometry.size.width < CoverCardMetrics.smallCardWidthPoints
                || geometry.size.height < CoverCardMetrics.smallCardHeightPoints
            let titleSize: CGFloat =
                isSmallCard ? CoverCardMetrics.smallTitleFontSizePoints : CoverCardMetrics.regularTitleFontSizePoints
            let subtitleSize: CGFloat =
                isSmallCard
                ? CoverCardMetrics.smallSubtitleFontSizePoints : CoverCardMetrics.regularSubtitleFontSizePoints
            let horizontalInset: CGFloat =
                isSmallCard
                ? CoverCardMetrics.smallHorizontalInsetPoints : CoverCardMetrics.regularHorizontalInsetPoints
            let verticalInset: CGFloat =
                isSmallCard ? CoverCardMetrics.smallVerticalInsetPoints : CoverCardMetrics.regularVerticalInsetPoints

            ZStack(alignment: .bottomLeading) {
                WebImage(url: coverURL, context: requestContext)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                    // aspectFill overflows, so it must be clipped to the current container.
                    .clipped()
                LinearGradient(
                    colors: [.black.opacity(CoverCardMetrics.gradientOpacity), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )

                .frame(height: geometry.size.height * CoverCardMetrics.gradientHeightFraction)
                .frame(maxWidth: .infinity, alignment: .bottom)

                VStack(alignment: .leading) {
                    Text(name)
                        .foregroundColor(.white)
                        .font(.system(size: titleSize, weight: .bold))
                        .lineLimit(CoverCardMetrics.titleLineLimit)
                        .minimumScaleFactor(CoverCardMetrics.textMinimumScaleFactor)
                        .padding(.horizontal, horizontalInset)
                    Group {
                        if let count = assetsCount {
                            Text(LocalizedText.format("%lld photos", Int64(count)))
                        } else {
                            Text(String(localized: "Photo count unavailable"))
                        }
                    }
                    .foregroundColor(.white.opacity(CoverCardMetrics.subtitleOpacity))
                    .font(.system(size: subtitleSize, weight: .regular))
                    .lineLimit(CoverCardMetrics.subtitleLineLimit)
                    .minimumScaleFactor(CoverCardMetrics.textMinimumScaleFactor)
                    .padding(.horizontal, horizontalInset)
                }
                .shadow(radius: CoverCardMetrics.textShadowRadiusPoints)
                .padding(.vertical, verticalInset)
            }
            // Clip the overlay too, so the gradient/text does not cover sibling views.
            .clipped()
            // Clipping does not shrink the tap area or the accessibility frame: without this, taps and VoiceOver
            // reach the card through its whole aspect-filled cover, which can extend over neighbouring cards.
            .contentShape([.interaction, .accessibility], Rectangle())
        }
    }
}

#Preview {
    CoverCardView(
        name: "Sample Album", coverURL: URL(string: "https://example.invalid/preview/j6dG19_DY-.jpg")!,
        assetsCount: 854)
}
