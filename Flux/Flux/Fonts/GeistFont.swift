import CoreText
import SwiftUI
import UIKit

enum GeistFont {
    static func register() {
        for name in ["Regular", "Medium", "SemiBold", "Bold", "Black"] {
            let file = "Geist-\(name)"
            guard let url = Bundle.main.url(forResource: file, withExtension: "ttf")
                ?? Bundle.main.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts")
            else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }

        if let largeTitle = UIFont(name: "Geist-SemiBold", size: 34),
           let title = UIFont(name: "Geist-SemiBold", size: 17) {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: largeTitle]
            UINavigationBar.appearance().titleTextAttributes = [.font: title]
        }
        if let tabTitle = UIFont(name: "Geist-Medium", size: 10) {
            UITabBarItem.appearance().setTitleTextAttributes([.font: tabTitle], for: .normal)
            UITabBarItem.appearance().setTitleTextAttributes([.font: tabTitle], for: .selected)
        }
    }
}

extension Font {
    static func geist(_ style: TextStyle, weight: Weight? = nil) -> Font {
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
        return geist(size: size, relativeTo: style, weight: weight ?? (style == .headline ? .semibold : .regular))
    }

    static func geist(size: CGFloat, relativeTo style: TextStyle = .body, weight: Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .black, .heavy: name = "Geist-Black"
        case .bold: name = "Geist-Bold"
        case .semibold: name = "Geist-SemiBold"
        case .medium: name = "Geist-Medium"
        default: name = "Geist-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }
}
