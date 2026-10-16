import CoreText
import SwiftUI

struct SettingsHomeWordmark: View {
    @ScaledMetric(relativeTo: .largeTitle) private var pointSize = 34
    @Environment(\.settingsPalette) private var palette

    var body: some View {
        let ivFont = IvLyricsFontLoader.variableFont(pointSize, weight: 800)
        let lyricsFont = IvLyricsFontLoader.variableFont(pointSize, weight: 250)
        let title = (Text(verbatim: "iv").font(Font(ivFont)) + Text(verbatim: "Lyrics").font(Font(lyricsFont)))
            .foregroundStyle(palette.text)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "ivLyrics"))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("settings.wordmark")
#if DEBUG
        if DebugSettingsUIHarness.enabled {
            // Inspect the same CoreText instances handed to Text, including font fallback.
            title.accessibilityValue("iv=\(Self.weight(ivFont));Lyrics=\(Self.weight(lyricsFont));ivFont=\(CTFontCopyPostScriptName(ivFont));lyricsFont=\(CTFontCopyPostScriptName(lyricsFont))")
        } else { title }
#else
        title
#endif
    }

#if DEBUG
    private static func weight(_ font: CTFont) -> Int {
        let variations = CTFontCopyVariation(font) as? [NSNumber: NSNumber]
        return variations?[NSNumber(value: 0x77676874)]?.intValue ?? -1
    }
#endif
}
