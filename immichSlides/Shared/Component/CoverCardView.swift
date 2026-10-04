//
//  CoverCardView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/2/5.
//

import SwiftUI
import SDWebImageSwiftUI

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
            let isSmallCard = geometry.size.width < 240 || geometry.size.height < 180
            let titleSize: CGFloat = isSmallCard ? 16 : 21
            let subtitleSize: CGFloat = isSmallCard ? 13 : 18
            let horizontalInset: CGFloat = isSmallCard ? 12 : 20
            let verticalInset: CGFloat = isSmallCard ? 3 : 5

            ZStack(alignment: .bottomLeading) {
                WebImage(url: coverURL, context: requestContext)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                    // aspectFill overflows, so it must be clipped to the current container.
                    .clipped()
                LinearGradient(
                    colors: [.black.opacity(0.9), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )

                .frame(height: geometry.size.height * 0.4)
                .frame(maxWidth: .infinity, alignment: .bottom)

                VStack(alignment: .leading) {
                    Text(name)
                        .foregroundColor(.white)
                        .font(.system(size: titleSize, weight: .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, horizontalInset)
                    Group {
                        if let count = assetsCount {
                            Text(LocalizedText.format("%lld photos", Int64(count)))
                        } else {
                            Text(String(localized: "Photo count unavailable"))
                        }
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .font(.system(size: subtitleSize, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, horizontalInset)
                }
                .shadow(radius: 30)
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
