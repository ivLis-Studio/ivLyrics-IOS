import CoreText
import Foundation
import SwiftUI

enum IvLyricsFontLoader {
    private static var registered = false

    static func registerPretendard() {
        guard !registered else { return }
        registered = true
        let names = [
            "Pretendard-Regular",
            "Pretendard-SemiBold",
            "Pretendard-Bold",
            "PretendardVariable"
        ]
        for name in names {
            let candidates = [
                Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Resources/Fonts"),
                Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts"),
                Bundle.main.url(forResource: name, withExtension: "ttf")
            ]
            guard let url = candidates.compactMap({ $0 }).first else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Preserve the numeric weight instead of mapping it to one of the static faces.
    static func variableFont(_ size: CGFloat, weight: CGFloat) -> CTFont {
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: "PretendardVariable-Regular",
            kCTFontVariationAttribute: [NSNumber(value: 0x77676874): weight] // OpenType wght
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}

extension Font {
    static func pretendard(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black:
            name = "Pretendard-Bold"
        case .semibold:
            name = "Pretendard-SemiBold"
        default:
            name = "Pretendard-Regular"
        }
        return .custom(name, size: size)
    }
}
