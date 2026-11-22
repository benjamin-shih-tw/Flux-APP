import CoreText
import SwiftUI
import UIKit

enum SourceHanFont {
    static func register() {
        guard let url = Bundle.main.url(forResource: "SourceHanSansTW-Bold", withExtension: "otf")
            ?? Bundle.main.url(forResource: "SourceHanSansTW-Bold", withExtension: "otf", subdirectory: "Fonts")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)

        if let largeTitle = UIFont(name: "SourceHanSansTW-Bold", size: 34),
           let title = UIFont(name: "SourceHanSansTW-Bold", size: 17) {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: largeTitle]
            UINavigationBar.appearance().titleTextAttributes = [.font: title]
        }
    }
}

extension Font {
    static func fluxFont(_ style: TextStyle, weight: Weight? = nil) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline, .body: size = 17
        case .callout: size = 16
        case .subheadline: size = 15
        case .footnote: size = 13
        case .caption: size = 12
        case .caption2: size = 11
        @unknown default: size = 17
        }
        return fluxFont(size: size, relativeTo: style, weight: weight ?? (style == .headline ? .semibold : .regular))
    }

    static func fluxFont(size: CGFloat, relativeTo style: TextStyle = .body, weight: Weight = .regular) -> Font {
        return .custom("SourceHanSansTW-Bold", size: size, relativeTo: style)
    }
}
