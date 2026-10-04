//
//  ModeCardView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/11.
//

import SwiftUI

struct ModeCardView: View {
    var icon: String = "dot.scope"
    let title: String
    let description: String
    var isCompact: Bool = false
    var isCompactHeight: Bool = false
    var isSelected: Bool = false
    var isFocused: Bool = false

    var body: some View {
        #if os(tvOS)
        ModeCardViewTV(
            icon: icon,
            title: title,
            description: description,
            isSelected: isSelected,
            isFocused: isFocused
        )
        #else
        ModeCardViewIOS(
            icon: icon,
            title: title,
            description: description,
            isCompact: isCompact,
            isCompactHeight: isCompactHeight,
            isSelected: isSelected
        )
        #endif
    }
}

#Preview {
    ModeCardView(
        icon: "photo.stack",
        title: "Shuffle All Photos",
        description: "Play all photos in the library in random order and start right away."
    )
}
