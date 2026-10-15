import SwiftUI

// MARK: - Sample lyrics

struct SettingsRuby: Sendable {
    let text: String
    let reading: String?
}

/// Sample lyric of the live previews: Japanese original with readings, romanization and the key of a
/// translation in the UI language.
struct SettingsSampleLine: Sendable {
    let segments: [SettingsRuby]
    let pronunciation: String
    let translationKey: String

    var original: String { segments.map(\.text).joined() }
}

enum SettingsPreviewSamples {
    static let title = "夜空のうた"
    static let artist = "ivLyrics"
    static let sky = SettingsSampleLine(
        segments: [SettingsRuby(text: "夜空", reading: "よぞら"), SettingsRuby(text: "に", reading: nil),
                   SettingsRuby(text: "光", reading: "ひか"), SettingsRuby(text: "る", reading: nil),
                   SettingsRuby(text: "星", reading: "ほし"), SettingsRuby(text: "を", reading: nil),
                   SettingsRuby(text: "見上", reading: "みあ"), SettingsRuby(text: "げた", reading: nil)],
        pronunciation: "yozora ni hikaru hoshi wo miageta",
        translationKey: "settings.preview.sample_line_0"
    )
    static let voice = SettingsSampleLine(
        segments: [SettingsRuby(text: "君", reading: "きみ"), SettingsRuby(text: "の", reading: nil),
                   SettingsRuby(text: "声", reading: "こえ"), SettingsRuby(text: "が", reading: nil),
                   SettingsRuby(text: "聞", reading: "き"), SettingsRuby(text: "こえる", reading: nil)],
        pronunciation: "kimi no koe ga kikoeru",
        translationKey: "settings.preview.sample_line_1"
    )
    static let tomorrow = SettingsSampleLine(
        segments: [SettingsRuby(text: "明日", reading: "あした"), SettingsRuby(text: "もきっと", reading: nil),
                   SettingsRuby(text: "晴", reading: "は"), SettingsRuby(text: "れるから", reading: nil)],
        pronunciation: "ashita mo kitto hareru kara",
        translationKey: "settings.preview.sample_line_2"
    )
}

/// Original line with optional furigana; falls back to wrapping plain text when it does not fit.
struct SettingsRubyLine: View {
    var line: SettingsSampleLine
    var size: CGFloat
    var weight: Font.Weight
    var color: Color
    var showsReadings: Bool
    var alignment: TextAlignment

    var body: some View {
        if showsReadings {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    ForEach(Array(line.segments.enumerated()), id: \.offset) { _, segment in
                        VStack(spacing: 0) {
                            Text(segment.reading ?? " ")
                                .font(.pretendard(max(7, size * 0.42), weight: .semibold))
                                .opacity(segment.reading == nil ? 0 : 0.82)
                            Text(segment.text)
                                .font(.pretendard(size, weight: weight))
                        }
                        .fixedSize()
                    }
                }
                plain
            }
            .foregroundStyle(color)
        } else {
            plain.foregroundStyle(color)
        }
    }

    private var plain: some View {
        Text(line.original)
            .font(.pretendard(size, weight: weight))
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Backgrounds

/// The lyrics background in miniature: album-art gradient, blurred gradient, video or a solid colour,
/// dimmed by the brightness setting.
struct SettingsPreviewBackground: View {
    var mode: String
    var brightness: Int
    var blur: Int
    var noise: Bool
    var solidColor: String
    var videoScale: Int = 100

    var body: some View {
        ZStack {
            switch mode {
            case AppSettings.backgroundSolid:
                Color(hex: solidColor)
            case AppSettings.backgroundBlurGradient:
                SettingsBlurredArt()
                    .blur(radius: CGFloat(blur) * 0.3)
                    .scaleEffect(1.12)
            case AppSettings.backgroundVideo:
                LinearGradient(colors: [Color(hex: "#22303A"), Color(hex: "#3A3A33"), Color(hex: "#1F3536"), Color(hex: "#262C35")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .scaleEffect(CGFloat(max(100, videoScale)) / 100)
                    .blur(radius: CGFloat(blur) * 0.3)
            default:
                SettingsArtGradient()
            }
            Color.black.opacity(Double(100 - min(100, max(0, brightness))) / 100 * 0.72)
            if noise { NoiseOverlay() }
        }
        .clipped()
    }
}

struct SettingsArtGradient: View {
    var body: some View {
        LinearGradient(colors: [Color(hex: "#A87B50"), Color(hex: "#6F6A52"), Color(hex: "#3D5D5C"), Color(hex: "#1A242A")],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct SettingsBlurredArt: View {
    var body: some View {
        ZStack {
            Color(hex: "#152026")
            RadialGradient(colors: [Color(hex: "#B88450").opacity(0.85), Color.clear], center: UnitPoint(x: 0.25, y: 0.35), startRadius: 0, endRadius: 190)
            RadialGradient(colors: [Color(hex: "#427673").opacity(0.9), Color.clear], center: UnitPoint(x: 0.78, y: 0.7), startRadius: 0, endRadius: 190)
        }
    }
}

private struct SettingsColorfulArt: View {
    var body: some View {
        ZStack {
            Color(hex: "#182025")
            RadialGradient(colors: [Color(hex: "#A87A4C"), Color.clear], center: UnitPoint(x: 0.15, y: 0.2), startRadius: 0, endRadius: 150)
            RadialGradient(colors: [Color(hex: "#3F7671"), Color.clear], center: UnitPoint(x: 0.85, y: 0.25), startRadius: 0, endRadius: 150)
            RadialGradient(colors: [Color(hex: "#4F6488"), Color.clear], center: UnitPoint(x: 0.55, y: 0.96), startRadius: 0, endRadius: 160)
        }
    }
}

/// Small picture of a background mode for the option cards.
struct BackgroundModeSwatch: View {
    var mode: String
    var solidColor: String
    var height: CGFloat = 56

    var body: some View {
        ZStack {
            switch mode {
            case AppSettings.backgroundSolid:
                Color(hex: solidColor)
            case AppSettings.backgroundBlurGradient:
                SettingsBlurredArt().blur(radius: 6).scaleEffect(1.2)
            case AppSettings.backgroundVideo:
                HStack(spacing: 0) {
                    ForEach(0..<12, id: \.self) { index in
                        (index.isMultiple(of: 2) ? Color(hex: "#17181C") : Color(hex: "#1D1F25"))
                    }
                }
                Image(systemName: "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.85))
            default:
                SettingsArtGradient()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Tonearm silhouettes (S, straight, J, linear tracking) drawn in a 24-point box.
struct TonearmGlyph: Shape {
    var style: String

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + (x - 12) * scale, y: rect.midY + (y - 12) * scale)
        }
        var path = Path()
        switch style {
        case AppSettings.vinylTonearmStyleStraight:
            path.move(to: point(18, 4))
            path.addLine(to: point(9, 18))
        case AppSettings.vinylTonearmStyleJ:
            path.move(to: point(18, 4))
            path.addLine(to: point(18, 13))
            path.addCurve(to: point(13, 19), control1: point(18, 16), control2: point(16, 18))
        case AppSettings.vinylTonearmStyleLinear:
            path.move(to: point(4, 6))
            path.addLine(to: point(20, 6))
            path.move(to: point(12, 6))
            path.addLine(to: point(12, 16))
        default:
            path.move(to: point(18, 4))
            path.addCurve(to: point(15, 15), control1: point(19.5, 8), control2: point(18.5, 12))
            path.addLine(to: point(11, 19))
        }
        return path
    }
}

// MARK: - Previews

private func settingsPreviewFont(_ family: String, size: CGFloat, weight: Font.Weight) -> Font {
    switch family {
    case "system": return .system(size: size, weight: weight)
    case "serif": return .system(size: size, weight: weight, design: .serif)
    case "monospace": return .system(size: size, weight: weight, design: .monospaced)
    default: return .pretendard(size, weight: weight)
    }
}

private func settingsPreviewWeight(_ value: Int) -> Font.Weight {
    switch value {
    case ..<150: return .ultraLight
    case ..<250: return .thin
    case ..<350: return .light
    case ..<450: return .regular
    case ..<550: return .medium
    case ..<650: return .semibold
    case ..<750: return .bold
    case ..<850: return .heavy
    default: return .black
    }
}

private func settingsTextAlignment(_ value: String) -> (TextAlignment, HorizontalAlignment, Alignment) {
    switch AppSettings.normalizeLyricsAlignment(value) {
    case "center": return (.center, .center, .center)
    case "right": return (.trailing, .trailing, .trailing)
    default: return (.leading, .leading, .leading)
    }
}

/// Lyrics page in miniature: header, the previous and the current line, optionally a cultural note.
struct SettingsLyricsPreview: View {
    @EnvironmentObject private var settings: AppSettings
    var annotation = false

    var body: some View {
        let _ = settings.typographyRevision
        let _ = settings.speakerColorRevision
        let typography = settings.typographySettings()
        let colors = settings.speakerColorSettings()
        let (textAlignment, stackAlignment, frameAlignment) = settingsTextAlignment(settings.lyricsTextAlignment)
        let headerTitle = typography.style(AppSettings.typoLyricsHeaderTitle)
        let headerArtist = typography.style(AppSettings.typoLyricsHeaderArtist)
        ZStack {
            SettingsPreviewBackground(
                mode: settings.backgroundMode,
                brightness: settings.backgroundBrightness,
                blur: settings.backgroundBlur,
                noise: settings.backgroundNoiseEnabled,
                solidColor: settings.backgroundSolidColor,
                videoScale: settings.backgroundVideoScale
            )
            VStack(alignment: stackAlignment, spacing: 14) {
                VStack(alignment: stackAlignment, spacing: 2) {
                    Text(SettingsPreviewSamples.title)
                        .font(.pretendard(15 * headerTitle.scale, weight: headerTitle.fontWeight))
                    Text(SettingsPreviewSamples.artist)
                        .font(.pretendard(11.5 * headerArtist.scale, weight: headerArtist.fontWeight))
                        .opacity(0.7)
                }
                if !annotation {
                    lyricLine(SettingsPreviewSamples.voice, active: false,
                              color: speakerColor(colors, slot: "female1"), typography: typography, alignment: textAlignment, stack: stackAlignment)
                }
                lyricLine(SettingsPreviewSamples.tomorrow, active: true,
                          color: speakerColor(colors, slot: AppSettings.speakerColorNormal), typography: typography, alignment: textAlignment, stack: stackAlignment)
                if annotation {
                    Text(settings.t("settings.preview.sample_note"))
                        .font(settingsPreviewFont(settings.culturalAnnotationsFontFamily,
                                                  size: CGFloat(settings.culturalAnnotationsFontSize) * 0.85,
                                                  weight: settingsPreviewWeight(settings.culturalAnnotationsFontWeight)))
                        .opacity(Double(settings.culturalAnnotationsOpacity) / 100)
                        .multilineTextAlignment(textAlignment)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(settings.culturalAnnotationsEnabled ? 1 : 0.35)
                }
            }
            .foregroundStyle(Color.white)
            .shadow(color: Color.black.opacity(0.35), radius: 3)
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
        .overlay(alignment: .topTrailing) { tag }
        .frame(maxWidth: .infinity, minHeight: 210)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private var tag: some View {
        Text(annotation ? settings.t("setting.cultural_annotations") : backgroundModeLabel)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(8)
    }

    private var backgroundModeLabel: String {
        switch settings.backgroundMode {
        case AppSettings.backgroundBlurGradient: return settings.t("background.mode.blur_gradient")
        case AppSettings.backgroundVideo: return settings.t("background.mode.video")
        case AppSettings.backgroundSolid: return settings.t("background.mode.solid")
        default: return settings.t("background.mode.gradient")
        }
    }

    private func speakerColor(_ colors: AppSettings.SpeakerColorSettings, slot: String) -> Color {
        settings.useSyncCreatorSpeakerColors ? Color(hex: colors.hex(slot)) : Color.white
    }

    private func lyricLine(_ line: SettingsSampleLine, active: Bool, color: Color,
                           typography: AppSettings.TypographySettings, alignment: TextAlignment,
                           stack: HorizontalAlignment) -> some View {
        let original = typography.style(AppSettings.typoLyricsOriginal)
        let pronunciation = typography.style(AppSettings.typoLyricsPronunciation)
        let translation = typography.style(AppSettings.typoLyricsTranslation)
        return VStack(alignment: stack, spacing: 1) {
            SettingsRubyLine(line: line, size: 21 * original.scale, weight: original.fontWeight, color: color,
                             showsReadings: settings.japaneseFuriganaEnabled, alignment: alignment)
            Text(line.pronunciation)
                .font(.pretendard(12.5 * pronunciation.scale, weight: pronunciation.fontWeight))
                .opacity(0.72)
            Text(settings.t(line.translationKey))
                .font(.pretendard(13.5 * translation.scale, weight: translation.fontWeight))
                .opacity(0.86)
        }
        .multilineTextAlignment(alignment)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(active ? 1 : 0.45)
    }
}

/// Main player screen in miniature: artwork, title, artist, the bottom lyric lines and a progress bar.
struct SettingsMainScreenPreview: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let _ = settings.typographyRevision
        let typography = settings.typographySettings()
        let items = AppSettings.normalizePreviewItems(settings.previewItems)
        let line = SettingsPreviewSamples.tomorrow
        let title = typography.style(AppSettings.typoMainTitle)
        let artist = typography.style(AppSettings.typoMainArtist)
        let original = typography.style(AppSettings.typoMainPreviewOriginal)
        let pronunciation = typography.style(AppSettings.typoMainPreviewPronunciation)
        let translation = typography.style(AppSettings.typoMainPreviewTranslation)
        ZStack {
            SettingsPreviewBackground(
                mode: settings.backgroundMode,
                brightness: settings.backgroundBrightness,
                blur: settings.backgroundBlur,
                noise: settings.backgroundNoiseEnabled,
                solidColor: settings.backgroundSolidColor,
                videoScale: settings.backgroundVideoScale
            )
            VStack(spacing: 6) {
                SettingsArtGradient()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(SettingsPreviewSamples.title)
                    .font(.pretendard(17 * title.scale, weight: title.fontWeight))
                Text(SettingsPreviewSamples.artist)
                    .font(.pretendard(12.5 * artist.scale, weight: artist.fontWeight))
                    .opacity(0.72)
                VStack(spacing: 2) {
                    if AppSettings.previewItemEnabled(items, AppSettings.previewItemOriginal) {
                        SettingsRubyLine(line: line, size: 14 * original.scale, weight: original.fontWeight, color: Color.white,
                                         showsReadings: settings.japaneseFuriganaEnabled, alignment: .center)
                    }
                    if AppSettings.previewItemEnabled(items, AppSettings.previewItemPronunciation) {
                        Text(line.pronunciation)
                            .font(.pretendard(11 * pronunciation.scale, weight: pronunciation.fontWeight))
                            .opacity(0.75)
                    }
                    if AppSettings.previewItemEnabled(items, AppSettings.previewItemTranslation) {
                        Text(settings.t(line.translationKey))
                            .font(.pretendard(11.5 * translation.scale, weight: translation.fontWeight))
                            .opacity(0.85)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(Color.white).frame(width: geometry.size.width * 0.36)
                    }
                }
                .frame(width: 180, height: 3)
                .padding(.top, 8)
            }
            .foregroundStyle(Color.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(18)
        }
        .frame(maxWidth: .infinity, minHeight: 230)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
}

/// Picture-in-picture window on a desk: orientation, background, artwork, alignment and sizes.
struct SettingsPipPreview: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.settingsPalette) private var palette

    var body: some View {
        let orientation = AppSettings.normalizePipOrientation(settings.pipOrientation)
        let size: CGSize = orientation == AppSettings.pipOrientationLandscape
            ? CGSize(width: 220, height: 124)
            : orientation == AppSettings.pipOrientationPortrait ? CGSize(width: 104, height: 184) : CGSize(width: 156, height: 156)
        let (textAlignment, stackAlignment, frameAlignment) = settingsTextAlignment(settings.pipLyricsTextAlignment)
        let lyricsScale = CGFloat(AppSettings.clampPipLyricsSizePercent(settings.pipLyricsSizePercent)) / 100
        let translationScale = CGFloat(AppSettings.clampPipTranslationSizePercent(settings.pipTranslationSizePercent)) / 100
        let line = SettingsPreviewSamples.tomorrow
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(palette.surface3)
            ZStack(alignment: .topLeading) {
                pipBackground
                if settings.pipShowArtwork {
                    SettingsArtGradient()
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(8)
                }
                VStack(alignment: stackAlignment, spacing: 2) {
                    Text(line.original)
                        .font(.pretendard(9.5 * lyricsScale, weight: .semibold))
                    Text(settings.t(line.translationKey))
                        .font(.pretendard(7.5 * lyricsScale * translationScale, weight: .medium))
                        .opacity(0.86)
                }
                .multilineTextAlignment(textAlignment)
                .foregroundStyle(Color.white)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var pipBackground: some View {
        switch AppSettings.normalizePipBackgroundMode(settings.pipBackgroundMode) {
        case AppSettings.pipBackgroundBlur:
            SettingsBlurredArt().blur(radius: 4).scaleEffect(1.15)
        case AppSettings.pipBackgroundGradient:
            SettingsColorfulArt()
        case AppSettings.pipBackgroundSolid:
            Color(hex: settings.backgroundSolidColor)
        default:
            SettingsArtGradient()
        }
    }
}

/// LP mode in miniature: record, label, tonearm and the lyric lines under the record.
struct SettingsVinylPreview: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = settings.typographyRevision
        let typography = settings.typographySettings()
        let record = CGFloat(AppSettings.clampVinylSizePercent(settings.vinylRecordSizePercent)) / 100
        let album = CGFloat(AppSettings.clampVinylSizePercent(settings.vinylAlbumSizePercent)) / 100
        let arm = CGFloat(AppSettings.clampVinylTonearmSizePercent(settings.vinylTonearmSizePercent)) / 100
        let spinning = settings.vinylAnimationsEnabled && settings.vinylCenterRotationEnabled && !reduceMotion
        let secondsPerTurn = 1.8 / max(0.25, Double(VinylMotionPolicy.speedPercent(settings.vinylRotationSpeedPercent)) / 100)
        let diameter = min(170, 132 * record)
        let line = SettingsPreviewSamples.tomorrow
        ZStack {
            SettingsBlurredArt().blur(radius: 4).scaleEffect(1.1)
            Color.black.opacity(0.3)
            VStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !spinning)) { context in
                        let angle = spinning
                            ? (context.date.timeIntervalSinceReferenceDate / secondsPerTurn * 360).truncatingRemainder(dividingBy: 360)
                            : 0
                        disc(diameter: diameter, album: album)
                            .rotationEffect(.degrees(angle))
                    }
                    .frame(width: 176, height: 176)
                    TonearmGlyph(style: AppSettings.normalizeVinylTonearmStyle(settings.vinylTonearmStyle))
                        .stroke(finishColor, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .frame(width: 92 * arm, height: 92 * arm)
                        .offset(x: 34, y: -6)
                }
                .frame(width: 220, height: 176)
                if settings.vinylLyricsEnabled {
                    let original = typography.style(AppSettings.typoVinylOriginal)
                    let pronunciation = typography.style(AppSettings.typoVinylPronunciation)
                    let translation = typography.style(AppSettings.typoVinylTranslation)
                    VStack(spacing: 2) {
                        Text(line.original)
                            .font(.pretendard(22 * original.scale, weight: original.fontWeight))
                        Text(line.pronunciation)
                            .font(.pretendard(15 * pronunciation.scale, weight: pronunciation.fontWeight))
                            .opacity(0.72)
                        Text(settings.t(line.translationKey))
                            .font(.pretendard(16 * translation.scale, weight: translation.fontWeight))
                            .opacity(0.86)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Color.white)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private var finishColor: Color {
        switch AppSettings.normalizeVinylTonearmFinish(settings.vinylTonearmFinish) {
        case AppSettings.vinylTonearmFinishSilver: return Color(hex: "#B9BEC7")
        case AppSettings.vinylTonearmFinishBlack: return Color(hex: "#1D1F24")
        default: return Color(hex: "#F2F2F2")
        }
    }

    private func disc(diameter: CGFloat, album: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color(hex: "#111111"))
            ForEach(1..<5, id: \.self) { ring in
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    .frame(width: diameter * (0.48 + CGFloat(ring) * 0.11), height: diameter * (0.48 + CGFloat(ring) * 0.11))
            }
            SettingsArtGradient()
                .frame(width: diameter * 0.38 * album, height: diameter * 0.38 * album)
                .clipShape(Circle())
            Circle().fill(Color(hex: "#111111")).frame(width: 6, height: 6)
        }
        .frame(width: diameter, height: diameter)
    }
}

