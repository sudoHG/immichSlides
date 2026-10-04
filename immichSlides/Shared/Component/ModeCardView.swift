//
//  ModeCardView.swift
//  immichSlides
//
//  Created by sudoHG on 2026/1/11.
//

import SwiftUI

struct ModeCardView: View {
    var icon: String = "dot.scope"
    // Preview/fallback default text is localized too.
    var title: String = String(localized: "Default Title")
    var description: String = String(
        localized: "Default description, default description, default description, default description")
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
    ModeCardView()
}
