import SwiftUI
import CoreText
import UIKit

enum ChromaTheme {
    static let background = Color(red: 0.12, green: 0.10, blue: 0.09)
    static let foreground = Color(red: 0.95, green: 0.92, blue: 0.89)
    static let card = Color(red: 0.16, green: 0.14, blue: 0.13)
    static let border = Color(red: 0.22, green: 0.19, blue: 0.18)
    static let primary = Color(red: 0.82, green: 0.45, blue: 0.34)
    static let primaryGlow = Color(red: 0.90, green: 0.57, blue: 0.43)
    static let secondary = Color(red: 0.20, green: 0.17, blue: 0.16)
    static let secondaryText = Color(red: 0.72, green: 0.67, blue: 0.63)
    static let muted = Color(red: 0.48, green: 0.43, blue: 0.39)
    static let canvasLine = Color(red: 0.56, green: 0.51, blue: 0.47)
    static let cream = Color(red: 0.95, green: 0.92, blue: 0.89)
    static let tabBar = Color(red: 0.14, green: 0.12, blue: 0.11).opacity(0.86)

    static let warmGradient = LinearGradient(
        colors: [primary, Color(red: 0.62, green: 0.39, blue: 0.25)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let darkGradient = LinearGradient(
        colors: [Color(red: 0.13, green: 0.11, blue: 0.10), Color(red: 0.08, green: 0.07, blue: 0.06)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let glowGradient = RadialGradient(
        colors: [primary.opacity(0.20), .clear],
        center: .center,
        startRadius: 8,
        endRadius: 120
    )
}

enum ChromaFontStyle {
    case bodyLight
    case bodyRegular
    case bodyMedium
    case bodyBold
    case displayRegular
    case displayMedium
    case displaySemiBold
    case displayBold
    case displayItalic
    case displayMediumItalic

    fileprivate var postScriptName: String {
        switch self {
        case .bodyLight:
            return "SpaceGrotesk-Light"
        case .bodyRegular:
            return "SpaceGrotesk-Light_Regular"
        case .bodyMedium:
            return "SpaceGrotesk-Light_Medium"
        case .bodyBold:
            return "SpaceGrotesk-Light_Bold"
        case .displayRegular:
            return "PlayfairDisplay-Regular"
        case .displayMedium:
            return "PlayfairDisplayRoman-Medium"
        case .displaySemiBold:
            return "PlayfairDisplayRoman-SemiBold"
        case .displayBold:
            return "PlayfairDisplayRoman-Bold"
        case .displayItalic:
            return "PlayfairDisplay-Italic"
        case .displayMediumItalic:
            return "PlayfairDisplayItalic-Medium"
        }
    }

    fileprivate var fallbackTextStyle: Font.TextStyle {
        switch self {
        case .bodyLight, .bodyRegular, .bodyMedium, .bodyBold:
            return .body
        case .displayRegular, .displayMedium, .displaySemiBold, .displayBold, .displayItalic, .displayMediumItalic:
            return .title
        }
    }
}

enum ChromaFonts {
    private static var didRegister = false

    static func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true

        let bundle = designBundle
        let fileNames = [
            "PlayfairDisplay-VariableFont_wght.ttf",
            "PlayfairDisplay-Italic-VariableFont_wght.ttf",
            "SpaceGrotesk-VariableFont_wght.ttf"
        ]

        for fileName in fileNames {
            guard let url = bundle.url(forResource: fileName, withExtension: nil) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func font(_ style: ChromaFontStyle, size: CGFloat) -> Font {
        registerIfNeeded()
        if let uiFont = UIFont(name: style.postScriptName, size: size) {
            return Font(uiFont)
        }

        switch style {
        case .bodyLight:
            return .system(size: size, weight: .light, design: .rounded)
        case .bodyRegular:
            return .system(size: size, weight: .regular, design: .rounded)
        case .bodyMedium:
            return .system(size: size, weight: .medium, design: .rounded)
        case .bodyBold:
            return .system(size: size, weight: .bold, design: .rounded)
        case .displayRegular, .displayItalic:
            return .system(size: size, weight: .regular, design: .serif)
        case .displayMedium, .displayMediumItalic:
            return .system(size: size, weight: .medium, design: .serif)
        case .displaySemiBold:
            return .system(size: size, weight: .semibold, design: .serif)
        case .displayBold:
            return .system(size: size, weight: .bold, design: .serif)
        }
    }

    private static var designBundle: Bundle {
#if SWIFT_PACKAGE
        return .module
#else
        return .main
#endif
    }
}

enum RootTab {
    case create
    case gallery
}
