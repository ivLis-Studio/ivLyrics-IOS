import Foundation
import Combine
import SwiftUI

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let outputLangSameUI = "same_ui"
    static let defaultSourceLang = "default"
    static let previewOriginal = "original"
    static let previewPronunciation = "pronunciation"
    static let previewTranslation = "translation"
    static let previewItemNone = 0
    static let previewItemOriginal = 1
    static let previewItemPronunciation = 1 << 1
    static let previewItemTranslation = 1 << 2
    static let backgroundGradient = "gradient-background"
    static let backgroundBlurGradient = "blur-gradient-background"
    static let backgroundVideo = "video-background"
    static let backgroundSolid = "solid-background"
    static let typoMainTitle = "main_title"
    static let typoMainArtist = "main_artist"
    static let typoMainPreviewOriginal = "main_preview_original"
    static let typoMainPreviewPronunciation = "main_preview_pronunciation"
    static let typoMainPreviewTranslation = "main_preview_translation"
    static let typoLyricsHeaderTitle = "lyrics_header_title"
    static let typoLyricsHeaderArtist = "lyrics_header_artist"
    static let typoLyricsOriginal = "lyrics_original"
    static let typoLyricsPronunciation = "lyrics_pronunciation"
    static let typoLyricsTranslation = "lyrics_translation"
    static let typoVinylOriginal = "vinyl_original"
    static let typoVinylPronunciation = "vinyl_pronunciation"
    static let typoVinylTranslation = "vinyl_translation"
    static let typoWeightRegular = "regular"
    static let typoWeightSemibold = "semibold"
    static let typoWeightBold = "bold"
    static let speakerColorNormal = "normal"
    static let pipOrientationLandscape = "landscape"
    static let pipOrientationPortrait = "portrait"
    static let pipOrientationSquare = "square"
    static let pipBackgroundCover = "cover"
    static let pipBackgroundBlur = "blur"
    static let pipBackgroundGradient = "gradient"
    static let pipBackgroundSolid = "solid"
    static let lyricsTypeKaraoke = "karaoke"
    static let lyricsTypeSynced = "synced"
    static let lyricsTypePlain = "plain"

    static let lyricsProviders: [LyricsProvider] = [
        LyricsProvider(
            id: "lrclib",
            name: "LRCLIB",
            author: "default",
            supportsNativeKaraoke: false,
            supportsIvLyricsSync: true,
            supportsSynced: true,
            supportsPlain: true
        ),
        LyricsProvider(
            id: "paxsenix",
            name: "Lyrically (Paxsenix)",
            author: "default",
            projectURL: PaxsenixLyricsProvider.projectURL,
            supportsNativeKaraoke: true,
            supportsIvLyricsSync: false,
            supportsSynced: true,
            supportsPlain: true
        ),
        LyricsProvider(
            id: "lyricsplus",
            name: "LyricsPlus",
            author: "default",
            projectURL: LyricsPlusProvider.projectURL,
            supportsNativeKaraoke: true,
            supportsIvLyricsSync: false,
            supportsSynced: true,
            supportsPlain: true
        ),
        LyricsProvider(
            id: "unison",
            name: "Unison",
            author: "default",
            projectURL: "https://github.com/better-lyrics/unison",
            defaultEnabled: false,
            supportsNativeKaraoke: true,
            supportsIvLyricsSync: false,
            supportsSynced: true,
            supportsPlain: true
        )
    ]
    static let defaultLyricsProviderOrder = lyricsProviders.map(\.id)

    static let providers: [Provider] = [
        Provider(id: "gemini", label: "Google Gemini", description: "Google AI Studio API 사용", defaultBaseUrl: "https://generativelanguage.googleapis.com/v1beta", defaultModel: "gemini-2.5-flash", apiKeyURL: "https://aistudio.google.com/apikey"),
        Provider(id: "chatgpt", label: "OpenAI ChatGPT", description: "OpenAI 호환 API 지원", defaultBaseUrl: "https://api.openai.com/v1", defaultModel: "gpt-4o-mini", apiKeyURL: "https://platform.openai.com/api-keys"),
        Provider(id: "claude", label: "Anthropic Claude", description: "Claude Messages API 사용", defaultBaseUrl: "https://api.anthropic.com/v1", defaultModel: "claude-sonnet-4-20250514", apiKeyURL: "https://console.anthropic.com/settings/keys"),
        Provider(id: "openrouter", label: "OpenRouter", description: "여러 AI 모델 라우팅", defaultBaseUrl: "https://openrouter.ai/api/v1", defaultModel: "anthropic/claude-3.5-sonnet", apiKeyURL: "https://openrouter.ai/keys"),
        Provider(id: "groq", label: "Groq", description: "빠른 OpenAI 호환 추론", defaultBaseUrl: "https://api.groq.com/openai/v1", defaultModel: "llama-3.3-70b-versatile", apiKeyURL: "https://console.groq.com/keys"),
        Provider(id: "perplexity", label: "Perplexity", description: "Sonar API 사용", defaultBaseUrl: "https://api.perplexity.ai", defaultModel: "sonar-pro", apiKeyURL: "https://www.perplexity.ai/settings/api"),
        Provider(id: "pollinations", label: "Pollinations.ai", description: "Pollinations OpenAI 호환 API", defaultBaseUrl: "https://gen.pollinations.ai", defaultModel: "openai", apiKeyURL: "https://enter.pollinations.ai"),
        Provider(id: "paxsenix", label: "paxsenix", description: "OpenAI 호환 API 서버", defaultBaseUrl: PaxsenixAIProvider.baseURL, defaultModel: "", apiKeyURL: PaxsenixAIProvider.dashboardURL)
    ]

    static let languages: [Language] = [
        Language(code: "ko", name: "Korean", nativeName: "한국어", phoneticDescription: "Korean Hangul pronunciation, e.g. こんにちは -> 콘니치와"),
        Language(code: "en", name: "English", nativeName: "English", phoneticDescription: "English romanization"),
        Language(code: "zh-CN", name: "Simplified Chinese", nativeName: "简体中文", phoneticDescription: "Chinese characters for pronunciation"),
        Language(code: "zh-TW", name: "Traditional Chinese", nativeName: "繁體中文", phoneticDescription: "Chinese characters for pronunciation"),
        Language(code: "ja", name: "Japanese", nativeName: "日本語", phoneticDescription: "Japanese Katakana pronunciation"),
        Language(code: "hi", name: "Hindi", nativeName: "हिन्दी", phoneticDescription: "Hindi Devanagari pronunciation"),
        Language(code: "es", name: "Spanish", nativeName: "Español", phoneticDescription: "Spanish phonetic spelling"),
        Language(code: "fr", name: "French", nativeName: "Français", phoneticDescription: "French phonetic spelling"),
        Language(code: "ar", name: "Arabic", nativeName: "العربية", phoneticDescription: "Arabic script pronunciation"),
        Language(code: "fa", name: "Persian", nativeName: "فارسی", phoneticDescription: "Persian script pronunciation"),
        Language(code: "de", name: "German", nativeName: "Deutsch", phoneticDescription: "German phonetic spelling"),
        Language(code: "ru", name: "Russian", nativeName: "Русский", phoneticDescription: "Russian Cyrillic pronunciation"),
        Language(code: "sv", name: "Swedish", nativeName: "Svenska", phoneticDescription: "Swedish phonetic spelling"),
        Language(code: "pt", name: "Portuguese", nativeName: "Português", phoneticDescription: "Portuguese phonetic spelling"),
        Language(code: "bn", name: "Bengali", nativeName: "বাংলা", phoneticDescription: "Bengali script pronunciation"),
        Language(code: "cs", name: "Czech", nativeName: "Čeština", phoneticDescription: "Czech phonetic spelling"),
        Language(code: "it", name: "Italian", nativeName: "Italiano", phoneticDescription: "Italian phonetic spelling"),
        Language(code: "th", name: "Thai", nativeName: "ภาษาไทย", phoneticDescription: "Thai script pronunciation"),
        Language(code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt", phoneticDescription: "Vietnamese phonetic spelling"),
        Language(code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia", phoneticDescription: "Indonesian phonetic spelling"),
        Language(code: "ms", name: "Malay", nativeName: "Bahasa Melayu", phoneticDescription: "Malay phonetic spelling"),
        Language(code: "tr", name: "Turkish", nativeName: "Türkçe", phoneticDescription: "Turkish phonetic spelling")
    ]

    static let typographySlots: [TypographySlot] = [
        TypographySlot(id: typoMainTitle, label: "Main Title", defaultSizePercent: 100, defaultWeight: typoWeightBold),
        TypographySlot(id: typoMainArtist, label: "Main Artist", defaultSizePercent: 100, defaultWeight: typoWeightRegular),
        TypographySlot(id: typoMainPreviewOriginal, label: "Preview Original", defaultSizePercent: 100, defaultWeight: typoWeightSemibold),
        TypographySlot(id: typoMainPreviewPronunciation, label: "Preview Pronunciation", defaultSizePercent: 100, defaultWeight: typoWeightSemibold),
        TypographySlot(id: typoMainPreviewTranslation, label: "Preview Translation", defaultSizePercent: 100, defaultWeight: typoWeightSemibold),
        TypographySlot(id: typoLyricsHeaderTitle, label: "Lyrics Header Title", defaultSizePercent: 100, defaultWeight: typoWeightBold),
        TypographySlot(id: typoLyricsHeaderArtist, label: "Lyrics Header Artist", defaultSizePercent: 100, defaultWeight: typoWeightRegular),
        TypographySlot(id: typoLyricsOriginal, label: "Lyrics Original", defaultSizePercent: 100, defaultWeight: typoWeightSemibold),
        TypographySlot(id: typoLyricsPronunciation, label: "Lyrics Pronunciation", defaultSizePercent: 100, defaultWeight: typoWeightSemibold),
        TypographySlot(id: typoLyricsTranslation, label: "Lyrics Translation", defaultSizePercent: 100, defaultWeight: typoWeightSemibold)
    ]

    static let vinylTypographySlots: [TypographySlot] = [
        TypographySlot(id: typoVinylOriginal, label: "Vinyl Original", defaultSizePercent: 100, defaultWeight: typoWeightBold),
        TypographySlot(id: typoVinylPronunciation, label: "Vinyl Pronunciation", defaultSizePercent: 100, defaultWeight: typoWeightSemibold),
        TypographySlot(id: typoVinylTranslation, label: "Vinyl Translation", defaultSizePercent: 100, defaultWeight: typoWeightSemibold)
    ]

    static let allTypographySlots = typographySlots + vinylTypographySlots

    static let speakerColorSlots: [SpeakerColorSlot] = [
        SpeakerColorSlot(id: speakerColorNormal, label: "Normal", defaultColor: "#ffffff"),
        SpeakerColorSlot(id: "duet1", label: "Duet 1", defaultColor: "#e4d8ff"),
        SpeakerColorSlot(id: "duet2", label: "Duet 2", defaultColor: "#d6e4ff"),
        SpeakerColorSlot(id: "duet3", label: "Duet 3", defaultColor: "#ffddf2"),
        SpeakerColorSlot(id: "duet4", label: "Duet 4", defaultColor: "#bfaeff"),
        SpeakerColorSlot(id: "duet5", label: "Duet 5", defaultColor: "#9d8cf2"),
        SpeakerColorSlot(id: "male1", label: "Male 1", defaultColor: "#a8ccff"),
        SpeakerColorSlot(id: "male2", label: "Male 2", defaultColor: "#9ae8d4"),
        SpeakerColorSlot(id: "male3", label: "Male 3", defaultColor: "#bfe8ff"),
        SpeakerColorSlot(id: "male4", label: "Male 4", defaultColor: "#7fb5e6"),
        SpeakerColorSlot(id: "male5", label: "Male 5", defaultColor: "#6cb8b8"),
        SpeakerColorSlot(id: "female1", label: "Female 1", defaultColor: "#ffb8c7"),
        SpeakerColorSlot(id: "female2", label: "Female 2", defaultColor: "#ffd6b3"),
        SpeakerColorSlot(id: "female3", label: "Female 3", defaultColor: "#f6c8ff"),
        SpeakerColorSlot(id: "female4", label: "Female 4", defaultColor: "#e6b4d4"),
        SpeakerColorSlot(id: "female5", label: "Female 5", defaultColor: "#f6e5a5")
    ]

    @Published var providerId: String { didSet { saveProviderIfNeeded() } }
    @Published var uiLang: String { didSet { set("ui_lang", uiLang) } }
    @Published var outputLang: String { didSet { saveOutputLanguageFromPublished() } }
    @Published var translationEnabled: Bool { didSet { saveDefaultLanguageRuleFromPublished() } }
    @Published var pronunciationEnabled: Bool { didSet { saveDefaultLanguageRuleFromPublished() } }
    @Published var metadataTranslationEnabled: Bool { didSet { set("metadata_translation_enabled", metadataTranslationEnabled) } }
    @Published var japaneseFuriganaEnabled: Bool { didSet { set("japanese_furigana_enabled", japaneseFuriganaEnabled) } }
    @Published var apiKeys: String { didSet { set("api_keys", apiKeys) } }
    @Published var pollinationsAccessToken: String { didSet { set("pollinations_access_token", pollinationsAccessToken) } }
    @Published var baseUrl: String { didSet { set("base_url", baseUrl) } }
    @Published var model: String { didSet { set("model", model) } }
    @Published var maxTokens: Int { didSet { set("max_tokens", max(256, maxTokens)) } }
    @Published var temperature: Double { didSet { set("temperature", min(2, max(0, temperature))) } }
    @Published var previewMode: String { didSet { savePreviewModeFromPublished() } }
    @Published var previewItems: Int { didSet { set("preview_items", Self.normalizePreviewItems(previewItems)) } }
    @Published var autoInstrumentalBreakEnabled: Bool { didSet { set("auto_instrumental_break", autoInstrumentalBreakEnabled) } }
    @Published var interludeLabelsEnabled: Bool { didSet { set("interlude_labels_enabled", interludeLabelsEnabled) } }
    @Published var syncedLyricsKaraokeAnimationEnabled: Bool { didSet { set("synced_lyrics_karaoke_animation", syncedLyricsKaraokeAnimationEnabled) } }
    @Published var karaokeBounceEffectEnabled: Bool { didSet { set("karaoke_bounce_effect", karaokeBounceEffectEnabled) } }
    @Published var karaokeDataAsLineSynced: Bool { didSet { set("karaoke_data_as_line_synced", karaokeDataAsLineSynced) } }
    @Published var useSyncCreatorSpeakerColors: Bool { didSet { set("use_sync_creator_speaker_colors", useSyncCreatorSpeakerColors) } }
    @Published var lyricsTextAlignment: String { didSet { set("lyrics_text_alignment", lyricsTextAlignment) } }
    @Published var keepScreenOn: Bool { didSet { set("keep_screen_on", keepScreenOn) } }
    @Published var landscapeAutoHideControls: Bool { didSet { set("landscape_auto_hide_controls", landscapeAutoHideControls) } }
    @Published var landscapeCenterNoLyrics: Bool { didSet { set("landscape_center_no_lyrics", landscapeCenterNoLyrics) } }
    @Published var pipShowArtwork: Bool { didSet { set("pip_show_artwork", pipShowArtwork) } }
    @Published var pipOrientation: String { didSet { set("pip_orientation", Self.normalizePipOrientation(pipOrientation)) } }
    @Published var pipBackgroundMode: String { didSet { set("pip_background_mode", Self.normalizePipBackgroundMode(pipBackgroundMode)) } }
    @Published var pipLyricsTextAlignment: String { didSet { set("pip_lyrics_text_alignment", Self.normalizeLyricsAlignment(pipLyricsTextAlignment)) } }
    @Published var pipLyricsSizePercent: Int { didSet { set("pip_lyrics_size_percent", Self.clampPipLyricsSizePercent(pipLyricsSizePercent)) } }
    @Published var pipTranslationSizePercent: Int { didSet { set("pip_translation_size_percent", Self.clampPipTranslationSizePercent(pipTranslationSizePercent)) } }
    @Published var vinylAlbumSizePercent: Int { didSet { set("vinyl_album_size_percent", Self.clampVinylSizePercent(vinylAlbumSizePercent)) } }
    @Published var vinylRecordSizePercent: Int { didSet { set("vinyl_record_size_percent", Self.clampVinylSizePercent(vinylRecordSizePercent)) } }
    @Published var vinylAnimationsEnabled: Bool { didSet { set("vinyl_animations_enabled", vinylAnimationsEnabled) } }
    @Published var backgroundMode: String { didSet { set("background_mode", backgroundMode); bumpBackgroundRevisionIfNeeded() } }
    @Published var backgroundBrightness: Int { didSet { set("background_brightness", backgroundBrightness); bumpBackgroundRevisionIfNeeded() } }
    @Published var backgroundBlur: Int { didSet { set("background_blur", backgroundBlur); bumpBackgroundRevisionIfNeeded() } }
    @Published var backgroundNoiseEnabled: Bool { didSet { set("background_noise", backgroundNoiseEnabled); bumpBackgroundRevisionIfNeeded() } }
    @Published var backgroundReduceMotionEnabled: Bool { didSet { set("background_reduce_motion", backgroundReduceMotionEnabled); bumpBackgroundRevisionIfNeeded() } }
    @Published var backgroundSolidColor: String { didSet { set("background_solid_color", Self.normalizeHexColor(backgroundSolidColor, fallback: "#1e3a8a")); bumpBackgroundRevisionIfNeeded() } }
    @Published var backgroundVideoScale: Int { didSet { set("background_video_scale", Self.clampBackgroundVideoScale(backgroundVideoScale)); bumpBackgroundRevisionIfNeeded() } }
    @Published var spotifyClientId: String { didSet { set("spotify_client_id", spotifyClientId) } }
    @Published var spotifyClientSecret: String { didSet { set("spotify_client_secret", spotifyClientSecret) } }
    @Published private(set) var lyricsProviderOrder: [String] { didSet { saveLyricsProviderSettingsIfNeeded() } }
    @Published private(set) var lyricsProviderEnabled: [String: Bool] { didSet { saveLyricsProviderSettingsIfNeeded() } }
    @Published private(set) var lyricsProviderTypes: [String: [String: Bool]] { didSet { saveLyricsProviderSettingsIfNeeded() } }
    @Published var preferSyncDataProvider: Bool { didSet { set("lyrics_prefer_sync_data_provider", preferSyncDataProvider) } }
    @Published var preferLyricsTypeOverProviderOrder: Bool { didSet { set("lyrics_prefer_type_over_provider", preferLyricsTypeOverProviderOrder) } }
    @Published private(set) var languageRulesRevision = 0
    @Published private(set) var backgroundSettingsRevision = 0
    @Published private(set) var typographyRevision = 0
    @Published private(set) var speakerColorRevision = 0

    private let defaults: UserDefaults
    private var isBootstrapping = true
    private var isApplyingRuleState = false
    private var cachedSnapshot: Snapshot?
    private var snapshotInvalidationCancellable: AnyCancellable?
    private let visualSettingsCacheLock = NSLock()
    private var cachedTypographySettings: (raw: String?, value: TypographySettings)?
    private var cachedSpeakerColorSettings: (raw: String?, value: SpeakerColorSettings)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let provider = Self.providerById(defaults.string(forKey: "provider") ?? "gemini")
        let loadedRuleConfig = Self.loadRuleConfig(defaults: defaults)
        let loadedOutputLang = Self.storedOutputLanguage(defaults: defaults, ruleConfig: loadedRuleConfig)
        let ruleConfig = loadedRuleConfig.withTarget(loadedOutputLang)
        providerId = provider.id
        uiLang = Self.normalizedUiLanguage(defaults.string(forKey: "ui_lang") ?? Self.autoTargetLanguage())
        outputLang = loadedOutputLang
        translationEnabled = ruleConfig.defaultRule.translationEnabled
        pronunciationEnabled = ruleConfig.defaultRule.pronunciationEnabled
        metadataTranslationEnabled = defaults.object(forKey: "metadata_translation_enabled") as? Bool ?? true
        japaneseFuriganaEnabled = defaults.object(forKey: "japanese_furigana_enabled") as? Bool ?? false
        apiKeys = defaults.string(forKey: "api_keys") ?? ""
        pollinationsAccessToken = defaults.string(forKey: "pollinations_access_token") ?? ""
        baseUrl = defaults.string(forKey: "base_url")?.trimmed.isEmpty == false ? defaults.string(forKey: "base_url")! : provider.defaultBaseUrl
        model = defaults.string(forKey: "model")?.trimmed.isEmpty == false ? defaults.string(forKey: "model")! : provider.defaultModel
        maxTokens = max(256, defaults.object(forKey: "max_tokens") as? Int ?? 16000)
        temperature = min(2, max(0, defaults.object(forKey: "temperature") as? Double ?? 0.3))
        let loadedPreviewMode = Self.normalizePreviewMode(defaults.string(forKey: "preview_mode") ?? Self.previewOriginal)
        previewMode = loadedPreviewMode
        previewItems = Self.normalizePreviewItems(defaults.object(forKey: "preview_items") as? Int ?? Self.previewItemsForMode(loadedPreviewMode))
        autoInstrumentalBreakEnabled = defaults.object(forKey: "auto_instrumental_break") as? Bool ?? true
        interludeLabelsEnabled = defaults.object(forKey: "interlude_labels_enabled") as? Bool ?? true
        syncedLyricsKaraokeAnimationEnabled = defaults.object(forKey: "synced_lyrics_karaoke_animation") as? Bool ?? true
        karaokeBounceEffectEnabled = defaults.object(forKey: "karaoke_bounce_effect") as? Bool ?? true
        karaokeDataAsLineSynced = defaults.object(forKey: "karaoke_data_as_line_synced") as? Bool ?? false
        useSyncCreatorSpeakerColors = defaults.object(forKey: "use_sync_creator_speaker_colors") as? Bool ?? true
        lyricsTextAlignment = Self.normalizeLyricsAlignment(defaults.string(forKey: "lyrics_text_alignment") ?? "left")
        keepScreenOn = defaults.object(forKey: "keep_screen_on") as? Bool ?? false
        landscapeAutoHideControls = defaults.object(forKey: "landscape_auto_hide_controls") as? Bool ?? true
        landscapeCenterNoLyrics = defaults.object(forKey: "landscape_center_no_lyrics") as? Bool ?? true
        pipShowArtwork = defaults.object(forKey: "pip_show_artwork") as? Bool ?? true
        pipOrientation = Self.normalizePipOrientation(defaults.string(forKey: "pip_orientation") ?? Self.pipOrientationSquare)
        pipBackgroundMode = Self.normalizePipBackgroundMode(defaults.string(forKey: "pip_background_mode") ?? Self.pipBackgroundCover)
        pipLyricsTextAlignment = Self.normalizeLyricsAlignment(defaults.string(forKey: "pip_lyrics_text_alignment") ?? "center")
        pipLyricsSizePercent = Self.clampPipLyricsSizePercent(defaults.object(forKey: "pip_lyrics_size_percent") as? Int ?? 150)
        pipTranslationSizePercent = Self.clampPipTranslationSizePercent(defaults.object(forKey: "pip_translation_size_percent") as? Int ?? 100)
        vinylAlbumSizePercent = Self.clampVinylSizePercent(defaults.object(forKey: "vinyl_album_size_percent") as? Int ?? 100)
        vinylRecordSizePercent = Self.clampVinylSizePercent(defaults.object(forKey: "vinyl_record_size_percent") as? Int ?? 100)
        vinylAnimationsEnabled = defaults.object(forKey: "vinyl_animations_enabled") as? Bool ?? true
        backgroundMode = Self.normalizeBackgroundMode(defaults.string(forKey: "background_mode") ?? Self.backgroundGradient)
        backgroundBrightness = min(100, max(0, defaults.object(forKey: "background_brightness") as? Int ?? 30))
        backgroundBlur = min(100, max(0, defaults.object(forKey: "background_blur") as? Int ?? 20))
        backgroundNoiseEnabled = defaults.object(forKey: "background_noise") as? Bool ?? false
        backgroundReduceMotionEnabled = defaults.object(forKey: "background_reduce_motion") as? Bool ?? false
        backgroundSolidColor = Self.normalizeHexColor(defaults.string(forKey: "background_solid_color") ?? "#1e3a8a", fallback: "#1e3a8a")
        backgroundVideoScale = Self.clampBackgroundVideoScale(defaults.object(forKey: "background_video_scale") as? Int ?? 100)
        spotifyClientId = defaults.string(forKey: "spotify_client_id") ?? ""
        spotifyClientSecret = defaults.string(forKey: "spotify_client_secret") ?? ""
        lyricsProviderOrder = Self.loadLyricsProviderOrder(defaults: defaults)
        lyricsProviderEnabled = Self.loadLyricsProviderEnabled(defaults: defaults)
        lyricsProviderTypes = Self.loadLyricsProviderTypes(defaults: defaults)
        preferSyncDataProvider = defaults.object(forKey: "lyrics_prefer_sync_data_provider") as? Bool ?? true
        preferLyricsTypeOverProviderOrder = defaults.object(forKey: "lyrics_prefer_type_over_provider") as? Bool ?? true
        isBootstrapping = false
        snapshotInvalidationCancellable = objectWillChange.sink { [weak self] _ in
            self?.cachedSnapshot = nil
        }
    }

    func t(_ key: String) -> String {
        AppI18n.t(uiLang, key)
    }

    func tf(_ key: String, _ arguments: CVarArg...) -> String {
        AppI18n.format(uiLang, key, arguments)
    }

    var snapshot: Snapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }
        let ruleConfig = Self.loadRuleConfig(defaults: defaults).withTarget(outputLang)
        let snapshot = Snapshot(
            uiLang: uiLang,
            outputLang: outputLang,
            provider: Self.providerById(providerId),
            defaultRule: ruleConfig.defaultRule,
            languageRules: ruleConfig.languageRules,
            translationEnabled: ruleConfig.defaultRule.translationEnabled,
            pronunciationEnabled: ruleConfig.defaultRule.pronunciationEnabled,
            metadataTranslationEnabled: metadataTranslationEnabled,
            japaneseFuriganaEnabled: japaneseFuriganaEnabled,
            apiKeys: apiKeys,
            pollinationsAccessToken: pollinationsAccessToken,
            baseUrl: baseUrl,
            model: model,
            maxTokens: maxTokens,
            temperature: temperature,
            previewMode: previewMode,
            previewItems: Self.normalizePreviewItems(previewItems),
            autoInstrumentalBreakEnabled: autoInstrumentalBreakEnabled,
            interludeLabelsEnabled: interludeLabelsEnabled,
            syncedLyricsKaraokeAnimationEnabled: syncedLyricsKaraokeAnimationEnabled,
            karaokeBounceEffectEnabled: karaokeBounceEffectEnabled,
            karaokeDataAsLineSynced: karaokeDataAsLineSynced,
            useSyncCreatorSpeakerColors: useSyncCreatorSpeakerColors,
            lyricsTextAlignment: lyricsTextAlignment,
            keepScreenOn: keepScreenOn,
            landscapeAutoHideControls: landscapeAutoHideControls,
            landscapeCenterNoLyrics: landscapeCenterNoLyrics,
            pipShowArtwork: pipShowArtwork,
            pipOrientation: Self.normalizePipOrientation(pipOrientation),
            pipBackgroundMode: Self.normalizePipBackgroundMode(pipBackgroundMode),
            pipLyricsTextAlignment: Self.normalizeLyricsAlignment(pipLyricsTextAlignment),
            pipLyricsSizePercent: Self.clampPipLyricsSizePercent(pipLyricsSizePercent),
            pipTranslationSizePercent: Self.clampPipTranslationSizePercent(pipTranslationSizePercent),
            backgroundMode: backgroundMode,
            backgroundBrightness: backgroundBrightness,
            backgroundBlur: backgroundBlur,
            backgroundNoiseEnabled: backgroundNoiseEnabled,
            backgroundReduceMotionEnabled: backgroundReduceMotionEnabled,
            backgroundSolidColor: backgroundSolidColor,
            backgroundVideoScale: backgroundVideoScale,
            typography: typographySettings(),
            speakerColors: speakerColorSettings(),
            spotifyClientId: spotifyClientId,
            spotifyClientSecret: spotifyClientSecret,
            lyricsProviderOrder: lyricsProviderOrder,
            lyricsProviderEnabled: lyricsProviderEnabled,
            lyricsProviderTypes: lyricsProviderTypes,
            preferSyncDataProvider: preferSyncDataProvider,
            preferLyricsTypeOverProviderOrder: preferLyricsTypeOverProviderOrder
        )
        cachedSnapshot = snapshot
        return snapshot
    }

    func setProvider(_ id: String) {
        let provider = Self.providerById(id)
        providerId = provider.id
        baseUrl = provider.defaultBaseUrl
        model = provider.defaultModel
    }

    func setPreviewItems(_ items: Int) {
        previewItems = Self.normalizePreviewItems(items)
    }

    func setLyricsProviderEnabled(_ providerId: String, enabled: Bool) {
        guard Self.lyricsProviderById(providerId) != nil else { return }
        lyricsProviderEnabled[providerId] = enabled
    }

    func setLyricsProviderTypeEnabled(_ providerId: String, type: String, enabled: Bool) {
        guard Self.lyricsProviderById(providerId) != nil,
              [Self.lyricsTypeKaraoke, Self.lyricsTypeSynced, Self.lyricsTypePlain].contains(type) else {
            return
        }
        var values = lyricsProviderTypes[providerId] ?? Self.defaultLyricsProviderTypes()
        values[type] = enabled
        lyricsProviderTypes[providerId] = values
    }

    func moveLyricsProvider(_ providerId: String, offset: Int) {
        guard let index = lyricsProviderOrder.firstIndex(of: providerId) else { return }
        let target = index + offset
        guard lyricsProviderOrder.indices.contains(target) else { return }
        lyricsProviderOrder.swapAt(index, target)
    }

    func languageRule(for sourceLang: String) -> LanguageRule {
        snapshot.ruleForSource(sourceLang)
    }

    func setLanguageRule(sourceLang: String, translationEnabled: Bool, pronunciationEnabled: Bool, targetLang: String? = nil) {
        let source = Self.normalizeSourceLanguageKey(sourceLang)
        let current = Self.loadRuleConfig(defaults: defaults).withTarget(outputLang)
        let target = Self.defaultSourceLang == source
            ? Self.normalizeOutputLanguage(targetLang ?? current.defaultRule.targetLang)
            : current.defaultRule.targetLang
        let nextRule = LanguageRule(
            sourceLang: source,
            translationEnabled: translationEnabled,
            pronunciationEnabled: pronunciationEnabled,
            targetLang: target
        )
        var defaultRule = current.defaultRule
        var rules = current.languageRules
        if source == Self.defaultSourceLang {
            defaultRule = nextRule
        } else {
            rules[source] = nextRule
        }
        saveRuleConfig(defaultRule: defaultRule, rules: rules)
        defaults.set(defaultRule.translationEnabled, forKey: "translation_enabled")
        defaults.set(defaultRule.pronunciationEnabled, forKey: "pronunciation_enabled")
        defaults.set(defaultRule.targetLang, forKey: "output_lang")
        applyDefaultRuleState(defaultRule)
        languageRulesRevision += 1
    }

    func resetLanguageRule(sourceLang: String) {
        let source = Self.normalizeSourceLanguageKey(sourceLang)
        guard source != Self.defaultSourceLang else { return }
        let current = Self.loadRuleConfig(defaults: defaults).withTarget(outputLang)
        var rules = current.languageRules
        rules.removeValue(forKey: source)
        saveRuleConfig(defaultRule: current.defaultRule, rules: rules)
        languageRulesRevision += 1
    }

    func typographySettings() -> TypographySettings {
        visualSettingsCacheLock.lock()
        defer { visualSettingsCacheLock.unlock() }
        let raw = defaults.string(forKey: "typography_settings_v1")
        if let cachedTypographySettings,
           cachedTypographySettings.raw == raw {
            return cachedTypographySettings.value
        }
        var storedObject: [String: Any] = [:]
        if let raw,
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            storedObject = object
        }
        var styles: [String: TypographyStyle] = [:]
        for slot in Self.allTypographySlots {
            if let slotObject = storedObject[slot.id] as? [String: Any] {
                styles[slot.id] = TypographyStyle(
                    sizePercent: slotObject["size"] as? Int ?? slot.defaultSizePercent,
                    weight: slotObject["weight"] as? String ?? slot.defaultWeight,
                    slot: slot
                )
            } else {
                styles[slot.id] = slot.defaultStyle
            }
        }
        let settings = TypographySettings(styles: styles)
        cachedTypographySettings = (raw, settings)
        return settings
    }

    func setTypographyStyle(slotId: String, sizePercent: Int, weight: String) {
        let slot = Self.typographySlotById(slotId)
        var styles = typographySettings().styles
        styles[slot.id] = TypographyStyle(sizePercent: sizePercent, weight: weight, slot: slot)
        saveTypographySettings(TypographySettings(styles: styles))
        typographyRevision += 1
    }

    func speakerColorSettings() -> SpeakerColorSettings {
        visualSettingsCacheLock.lock()
        defer { visualSettingsCacheLock.unlock() }
        let raw = defaults.string(forKey: "speaker_color_settings_v1")
        if let cachedSpeakerColorSettings,
           cachedSpeakerColorSettings.raw == raw {
            return cachedSpeakerColorSettings.value
        }
        var storedObject: [String: Any] = [:]
        if let raw,
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            storedObject = object
        }
        var colors: [String: String] = [:]
        for slot in Self.speakerColorSlots {
            colors[slot.id] = Self.normalizeHexColor(storedObject[slot.id] as? String ?? "", fallback: slot.defaultColor)
        }
        let settings = SpeakerColorSettings(colors: colors)
        cachedSpeakerColorSettings = (raw, settings)
        return settings
    }

    func setSpeakerColor(slotId: String, color: String) {
        let slot = Self.speakerColorSlotById(slotId)
        var colors = speakerColorSettings().colors
        colors[slot.id] = Self.normalizeHexColor(color, fallback: slot.defaultColor)
        saveSpeakerColorSettings(SpeakerColorSettings(colors: colors))
        speakerColorRevision += 1
    }

    func resetSpeakerColors() {
        defaults.removeObject(forKey: "speaker_color_settings_v1")
        cachedSnapshot = nil
        speakerColorRevision += 1
    }

    var globalBackgroundSettings: BackgroundSettings {
        BackgroundSettings(
            mode: backgroundMode,
            brightness: backgroundBrightness,
            blur: backgroundBlur,
            noise: backgroundNoiseEnabled,
            reduceMotion: backgroundReduceMotionEnabled,
            solidColor: backgroundSolidColor,
            videoScale: backgroundVideoScale
        )
    }

    func effectiveBackgroundSettings(trackKey: String) -> BackgroundSettings {
        trackBackgroundSettings(trackKey) ?? globalBackgroundSettings
    }

    func trackBackgroundSettings(_ trackKey: String) -> BackgroundSettings? {
        let key = trackKey.trimmed
        guard !key.isEmpty,
              let raw = defaults.string(forKey: "track_background_settings_v1"),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settingsObject = object[key] as? [String: Any] else {
            return nil
        }
        return Self.backgroundSettings(from: settingsObject, fallback: globalBackgroundSettings)
    }

    func setTrackBackgroundSettings(_ trackKey: String, _ settings: BackgroundSettings?) {
        let key = trackKey.trimmed
        guard !key.isEmpty else { return }
        var object = trackBackgroundSettingsObject()
        if let settings {
            object[key] = Self.backgroundSettingsJson(settings)
        } else {
            object.removeValue(forKey: key)
        }
        saveTrackBackgroundSettingsObject(object)
        backgroundSettingsRevision += 1
    }

    func clearTrackBackgroundSettings(_ trackKey: String) {
        setTrackBackgroundSettings(trackKey, nil)
    }

    func trackSyncOffsetMs(_ key: String) -> Int {
        offsetMap("track_sync_offsets_v1")[key] ?? 0
    }

    func setTrackSyncOffsetMs(_ key: String, _ offset: Int) {
        setOffset("track_sync_offsets_v1", key: key, offset: offset)
    }

    func trackVideoSyncOffsetMs(_ key: String) -> Int {
        offsetMap("track_video_sync_offsets_v1")[key] ?? 0
    }

    func setTrackVideoSyncOffsetMs(_ key: String, _ offset: Int) {
        setOffset("track_video_sync_offsets_v1", key: key, offset: offset)
    }

    func bluetoothSyncOffsetMs(_ key: String) -> Int {
        offsetMap("bluetooth_sync_offsets_v1")[key] ?? 0
    }

    func setBluetoothSyncOffsetMs(_ key: String, _ offset: Int) {
        setOffset("bluetooth_sync_offsets_v1", key: key, offset: offset)
    }

    private func offsetMap(_ prefsKey: String) -> [String: Int] {
        guard let raw = defaults.string(forKey: prefsKey),
              let data = raw.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return object
    }

    private func setOffset(_ prefsKey: String, key: String, offset: Int) {
        let safeKey = key.trimmed
        guard !safeKey.isEmpty else { return }
        var map = offsetMap(prefsKey)
        let safeOffset = min(10_000, max(-10_000, offset))
        if safeOffset == 0 {
            map.removeValue(forKey: safeKey)
        } else {
            map[safeKey] = safeOffset
        }
        if let data = try? JSONEncoder().encode(map), let raw = String(data: data, encoding: .utf8) {
            defaults.set(raw, forKey: prefsKey)
        }
    }

    private func saveProviderIfNeeded() {
        guard !isBootstrapping else { return }
        set("provider", Self.providerById(providerId).id)
    }

    private func savePreviewModeFromPublished() {
        guard !isBootstrapping else { return }
        let normalized = Self.normalizePreviewMode(previewMode)
        defaults.set(normalized, forKey: "preview_mode")
        let items = Self.previewItemsForMode(normalized)
        if previewItems != items {
            previewItems = items
        } else {
            defaults.set(items, forKey: "preview_items")
        }
    }

    private func saveOutputLanguageFromPublished() {
        guard !isBootstrapping, !isApplyingRuleState else { return }
        let target = Self.normalizeOutputLanguage(outputLang)
        let current = Self.loadRuleConfig(defaults: defaults)
        let updated = current.withTarget(target)
        saveRuleConfig(defaultRule: updated.defaultRule, rules: updated.languageRules)
        defaults.set(target, forKey: "output_lang")
        defaults.removeObject(forKey: "pronunciation_lang")
        if outputLang != target {
            applyDefaultRuleState(updated.defaultRule)
        }
        languageRulesRevision += 1
    }

    private func saveDefaultLanguageRuleFromPublished() {
        guard !isBootstrapping, !isApplyingRuleState else { return }
        let current = Self.loadRuleConfig(defaults: defaults).withTarget(outputLang)
        let defaultRule = LanguageRule(
            sourceLang: Self.defaultSourceLang,
            translationEnabled: translationEnabled,
            pronunciationEnabled: pronunciationEnabled,
            targetLang: current.defaultRule.targetLang
        )
        saveRuleConfig(defaultRule: defaultRule, rules: current.languageRules)
        defaults.set(defaultRule.translationEnabled, forKey: "translation_enabled")
        defaults.set(defaultRule.pronunciationEnabled, forKey: "pronunciation_enabled")
        languageRulesRevision += 1
    }

    private func applyDefaultRuleState(_ rule: LanguageRule) {
        isApplyingRuleState = true
        outputLang = Self.normalizeOutputLanguage(rule.targetLang)
        translationEnabled = rule.translationEnabled
        pronunciationEnabled = rule.pronunciationEnabled
        isApplyingRuleState = false
    }

    private func saveRuleConfig(defaultRule: LanguageRule, rules: [String: LanguageRule]) {
        var object: [String: Any] = ["default": Self.ruleJson(defaultRule)]
        var rulesObject: [String: Any] = [:]
        for key in rules.keys.sorted() {
            guard let rule = rules[key] else { continue }
            rulesObject[key] = Self.ruleJson(rule)
        }
        object["rules"] = rulesObject
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(raw, forKey: "language_rules_v2")
        cachedSnapshot = nil
    }

    private func saveTypographySettings(_ typography: TypographySettings) {
        var object: [String: Any] = [:]
        for slot in Self.allTypographySlots {
            let style = typography.style(slot.id)
            object[slot.id] = [
                "size": style.sizePercent,
                "weight": style.weight
            ]
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(raw, forKey: "typography_settings_v1")
        cachedSnapshot = nil
    }

    private func saveSpeakerColorSettings(_ settings: SpeakerColorSettings) {
        var object: [String: Any] = [:]
        for slot in Self.speakerColorSlots {
            object[slot.id] = settings.hex(slot.id)
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(raw, forKey: "speaker_color_settings_v1")
        cachedSnapshot = nil
    }

    private func saveLyricsProviderSettingsIfNeeded() {
        guard !isBootstrapping else { return }
        let order = Self.normalizedLyricsProviderOrder(lyricsProviderOrder)
        let enabled = Self.normalizedLyricsProviderEnabled(lyricsProviderEnabled)
        let types = Self.normalizedLyricsProviderTypes(lyricsProviderTypes)
        if let data = try? JSONSerialization.data(withJSONObject: order),
           let raw = String(data: data, encoding: .utf8) {
            defaults.set(raw, forKey: "lyrics_provider_order_v1")
        }
        if let data = try? JSONSerialization.data(withJSONObject: enabled),
           let raw = String(data: data, encoding: .utf8) {
            defaults.set(raw, forKey: "lyrics_provider_enabled_v1")
        }
        if let data = try? JSONSerialization.data(withJSONObject: types),
           let raw = String(data: data, encoding: .utf8) {
            defaults.set(raw, forKey: "lyrics_provider_types_v1")
        }
        cachedSnapshot = nil
    }

    private func bumpBackgroundRevisionIfNeeded() {
        guard !isBootstrapping else { return }
        backgroundSettingsRevision += 1
    }

    private func trackBackgroundSettingsObject() -> [String: Any] {
        guard let raw = defaults.string(forKey: "track_background_settings_v1"),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func saveTrackBackgroundSettingsObject(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let raw = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(raw, forKey: "track_background_settings_v1")
    }

    private func set(_ key: String, _ value: String) {
        guard !isBootstrapping else { return }
        defaults.set(value, forKey: key)
    }

    private func set(_ key: String, _ value: Bool) {
        guard !isBootstrapping else { return }
        defaults.set(value, forKey: key)
    }

    private func set(_ key: String, _ value: Int) {
        guard !isBootstrapping else { return }
        defaults.set(value, forKey: key)
    }

    private func set(_ key: String, _ value: Double) {
        guard !isBootstrapping else { return }
        defaults.set(value, forKey: key)
    }

    static func providerById(_ id: String) -> Provider {
        providers.first { $0.id == id.trimmed.lowercased() } ?? providers[0]
    }

    static func lyricsProviderById(_ id: String) -> LyricsProvider? {
        lyricsProviders.first { $0.id == id.trimmed.lowercased() }
    }

    private static func loadLyricsProviderOrder(defaults: UserDefaults) -> [String] {
        guard let raw = defaults.string(forKey: "lyrics_provider_order_v1"),
              let data = raw.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return defaultLyricsProviderOrder
        }
        return normalizedLyricsProviderOrder(values)
    }

    private static func loadLyricsProviderEnabled(defaults: UserDefaults) -> [String: Bool] {
        guard let raw = defaults.string(forKey: "lyrics_provider_enabled_v1"),
              let data = raw.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] else {
            return normalizedLyricsProviderEnabled([:])
        }
        return normalizedLyricsProviderEnabled(values)
    }

    private static func loadLyricsProviderTypes(defaults: UserDefaults) -> [String: [String: Bool]] {
        guard let raw = defaults.string(forKey: "lyrics_provider_types_v1"),
              let data = raw.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Bool]] else {
            return normalizedLyricsProviderTypes([:])
        }
        return normalizedLyricsProviderTypes(values)
    }

    static func normalizedLyricsProviderOrder(_ values: [String]) -> [String] {
        let known = Set(defaultLyricsProviderOrder)
        var seen = Set<String>()
        var result = values.compactMap { raw -> String? in
            let value = raw.trimmed.lowercased()
            guard known.contains(value), seen.insert(value).inserted else { return nil }
            return value
        }
        for (defaultIndex, providerId) in defaultLyricsProviderOrder.enumerated() where seen.insert(providerId).inserted {
            let previous = defaultLyricsProviderOrder[..<defaultIndex].reversed().first { result.contains($0) }
            if let previous, let insertionIndex = result.firstIndex(of: previous) {
                result.insert(providerId, at: insertionIndex + 1)
                continue
            }
            let next = defaultLyricsProviderOrder.dropFirst(defaultIndex + 1).first { result.contains($0) }
            if let next, let insertionIndex = result.firstIndex(of: next) {
                result.insert(providerId, at: insertionIndex)
            } else {
                result.append(providerId)
            }
        }
        return result
    }

    private static func normalizedLyricsProviderEnabled(_ values: [String: Bool]) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: defaultLyricsProviderOrder.map { providerId in
            let fallback = lyricsProviderById(providerId)?.defaultEnabled ?? true
            return (providerId, values[providerId] ?? fallback)
        })
    }

    private static func defaultLyricsProviderTypes() -> [String: Bool] {
        [lyricsTypeKaraoke: true, lyricsTypeSynced: true, lyricsTypePlain: true]
    }

    private static func normalizedLyricsProviderTypes(_ values: [String: [String: Bool]]) -> [String: [String: Bool]] {
        Dictionary(uniqueKeysWithValues: defaultLyricsProviderOrder.map { providerId in
            let stored = values[providerId] ?? [:]
            return (
                providerId,
                [
                    lyricsTypeKaraoke: stored[lyricsTypeKaraoke] ?? true,
                    lyricsTypeSynced: stored[lyricsTypeSynced] ?? true,
                    lyricsTypePlain: stored[lyricsTypePlain] ?? true
                ]
            )
        })
    }

    static func languageInfo(_ code: String) -> Language {
        let normalized = normalizeLanguageCode(code).lowercased()
        return languages.first { $0.code.lowercased() == normalized } ?? languages[1]
    }

    static func normalizeLanguageCode(_ lang: String?) -> String {
        let value = (lang ?? "").trimmed
        if value.isEmpty { return "" }
        let lower = value.replacingOccurrences(of: "_", with: "-").lowercased()
        switch lower {
        case "jp": return "ja"
        case "kr": return "ko"
        case "cn", "zh", "zh-hans", "zh-cn", "zh-sg": return "zh-CN"
        case "tw", "hk", "zh-hant", "zh-tw", "zh-hk": return "zh-TW"
        default:
            if let language = languages.first(where: { $0.code.lowercased() == lower }) {
                return language.code
            }
            let base = lower.split(separator: "-").first.map(String.init) ?? lower
            return languages.first(where: { $0.code.lowercased() == base })?.code ?? value
        }
    }

    static func normalizeSourceLanguageKey(_ lang: String?) -> String {
        let value = (lang ?? "").trimmed
        if value.isEmpty
            || value.caseInsensitiveCompare(defaultSourceLang) == .orderedSame
            || value == "*"
            || value.caseInsensitiveCompare("all") == .orderedSame {
            return defaultSourceLang
        }
        let normalized = normalizeLanguageCode(value)
        return normalized.isEmpty ? defaultSourceLang : normalized
    }

    static func normalizeOutputLanguage(_ lang: String?) -> String {
        let value = (lang ?? "").trimmed
        if value.isEmpty
            || value.lowercased() == "auto"
            || value.lowercased() == "ui"
            || value.lowercased() == "ui_lang"
            || value.lowercased() == "ui_language"
            || value.lowercased() == outputLangSameUI {
            return outputLangSameUI
        }
        let normalized = normalizeLanguageCode(value)
        return languages.contains { $0.code.lowercased() == normalized.lowercased() } ? normalized : outputLangSameUI
    }

    static func resolveOutputLanguage(_ outputLang: String, uiLang: String) -> String {
        let normalized = normalizeOutputLanguage(outputLang)
        if normalized == outputLangSameUI {
            let ui = normalizedUiLanguage(uiLang)
            return languages.contains { $0.code.lowercased() == ui.lowercased() } ? ui : autoTargetLanguage()
        }
        return normalizeLanguageCode(normalized)
    }

    static func normalizedUiLanguage(_ lang: String?) -> String {
        let normalized = normalizeLanguageCode(lang)
        if languages.contains(where: { $0.code.lowercased() == normalized.lowercased() }) {
            return normalized
        }
        let auto = autoTargetLanguage()
        return languages.contains(where: { $0.code.lowercased() == auto.lowercased() }) ? auto : "en"
    }

    static func normalizePreviewMode(_ mode: String?) -> String {
        let value = (mode ?? "").trimmed.lowercased()
        if value == previewTranslation { return previewTranslation }
        if value == previewPronunciation { return previewPronunciation }
        return previewOriginal
    }

    static func normalizeTypographyWeight(_ weight: String?, fallback: String = typoWeightSemibold) -> String {
        let value = (weight ?? "").trimmed.lowercased()
        if value == typoWeightRegular || value == typoWeightSemibold || value == typoWeightBold {
            return value
        }
        let safeFallback = fallback.trimmed.lowercased()
        if safeFallback == typoWeightRegular || safeFallback == typoWeightBold {
            return safeFallback
        }
        return typoWeightSemibold
    }

    static func typographySlotById(_ slotId: String?) -> TypographySlot {
        let normalized = (slotId ?? "").trimmed
        return allTypographySlots.first { $0.id == normalized } ?? typographySlots[0]
    }

    static func clampVinylSizePercent(_ value: Int) -> Int {
        min(140, max(70, value))
    }

    static func speakerColorSlotById(_ slotId: String?) -> SpeakerColorSlot {
        let normalized = (slotId ?? "").trimmed
        return speakerColorSlots.first { $0.id == normalized } ?? speakerColorSlots[0]
    }

    static func normalizePreviewItems(_ previewItems: Int) -> Int {
        let allowed = previewItemOriginal | previewItemPronunciation | previewItemTranslation
        return previewItems & allowed
    }

    static func previewItemEnabled(_ previewItems: Int, _ item: Int) -> Bool {
        (normalizePreviewItems(previewItems) & item) == item
    }

    static func normalizeBackgroundMode(_ mode: String?) -> String {
        let value = (mode ?? "").trimmed.lowercased()
        if [backgroundGradient, backgroundBlurGradient, backgroundVideo, backgroundSolid].contains(value) {
            return value
        }
        return backgroundGradient
    }

    static func normalizeLyricsAlignment(_ alignment: String?) -> String {
        let value = (alignment ?? "").trimmed.lowercased()
        if value == "center" || value == "right" {
            return value
        }
        return "left"
    }

    static func normalizePipOrientation(_ orientation: String?) -> String {
        let value = (orientation ?? "").trimmed.lowercased()
        if value == pipOrientationPortrait { return pipOrientationPortrait }
        if value == pipOrientationSquare { return pipOrientationSquare }
        return pipOrientationLandscape
    }

    static func normalizePipBackgroundMode(_ mode: String?) -> String {
        let value = (mode ?? "").trimmed.lowercased()
        if [pipBackgroundCover, pipBackgroundBlur, pipBackgroundGradient, pipBackgroundSolid].contains(value) {
            return value
        }
        switch value {
        case "artwork": return pipBackgroundCover
        case "blur-gradient": return pipBackgroundGradient
        default: return pipBackgroundCover
        }
    }

    static func normalizeHexColor(_ color: String, fallback: String) -> String {
        let value = color.trimmed
        guard value.range(of: #"^#?[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil else {
            return fallback
        }
        return (value.hasPrefix("#") ? value : "#\(value)").lowercased()
    }

    static func isHexColor(_ color: String) -> Bool {
        color.trimmed.range(of: #"^#?[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil
    }

    static func clampBackgroundVideoScale(_ value: Int) -> Int {
        min(180, max(100, value))
    }

    static func clampPipLyricsSizePercent(_ value: Int) -> Int {
        min(180, max(50, value))
    }

    static func clampPipTranslationSizePercent(_ value: Int) -> Int {
        min(250, max(50, value))
    }

    static func autoTargetLanguage() -> String {
        let identifier = Locale.current.identifier
        if identifier.lowercased().hasPrefix("zh") {
            return identifier.contains("TW") || identifier.contains("HK") || identifier.contains("MO") ? "zh-TW" : "zh-CN"
        }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let normalized = normalizeLanguageCode(language)
        return languages.contains { $0.code.lowercased() == normalized.lowercased() } ? normalized : "en"
    }

    private static func previewItemsForMode(_ mode: String?) -> Int {
        let normalized = normalizePreviewMode(mode)
        if normalized == previewTranslation { return previewItemTranslation }
        if normalized == previewPronunciation { return previewItemPronunciation }
        return previewItemOriginal
    }

    static func isSameLanguage(_ sourceLang: String, _ targetLang: String) -> Bool {
        let source = normalizeLanguageCode(sourceLang)
        let target = normalizeLanguageCode(targetLang)
        if source.isEmpty || target.isEmpty || target.lowercased() == "auto" || target.lowercased() == outputLangSameUI {
            return false
        }
        return source.caseInsensitiveCompare(target) == .orderedSame
    }

    private static func loadRuleConfig(defaults: UserDefaults) -> RuleConfig {
        let legacyTranslation = defaults.object(forKey: "translation_enabled") as? Bool ?? false
        let legacyPronunciation = defaults.object(forKey: "pronunciation_enabled") as? Bool ?? false
        let legacyTarget = normalizeTargetRules(defaults.string(forKey: "target_lang") ?? outputLangSameUI)
        let legacyTargetRules = parseTargetRules(legacyTarget)
        let defaultTarget = firstNonEmpty(
            legacyTargetRules["default"],
            legacyTargetRules["*"],
            legacyTargetRules.isEmpty ? legacyTarget : outputLangSameUI
        )
        var defaultRule = LanguageRule(
            sourceLang: defaultSourceLang,
            translationEnabled: legacyTranslation,
            pronunciationEnabled: legacyPronunciation,
            targetLang: defaultTarget
        )
        var rules: [String: LanguageRule] = [:]
        for (rawSource, target) in legacyTargetRules {
            let source = normalizeSourceLanguageKey(rawSource)
            guard source != defaultSourceLang else { continue }
            rules[source] = LanguageRule(
                sourceLang: source,
                translationEnabled: legacyTranslation,
                pronunciationEnabled: legacyPronunciation,
                targetLang: target
            )
        }

        guard let stored = defaults.string(forKey: "language_rules_v2"),
              !stored.trimmed.isEmpty,
              let data = stored.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RuleConfig(defaultRule: defaultRule, languageRules: rules)
        }

        if let defaultObject = object["default"] as? [String: Any] {
            defaultRule = parseRule(source: defaultSourceLang, object: defaultObject, fallback: defaultRule)
        }
        if let rulesObject = object["rules"] as? [String: Any] {
            for (key, value) in rulesObject {
                let source = normalizeSourceLanguageKey(key)
                guard source != defaultSourceLang, let ruleObject = value as? [String: Any] else { continue }
                let fallback = rules[source] ?? LanguageRule(
                    sourceLang: source,
                    translationEnabled: defaultRule.translationEnabled,
                    pronunciationEnabled: defaultRule.pronunciationEnabled,
                    targetLang: defaultRule.targetLang
                )
                rules[source] = parseRule(source: source, object: ruleObject, fallback: fallback)
            }
        }
        return RuleConfig(defaultRule: defaultRule, languageRules: rules)
    }

    private static func storedOutputLanguage(defaults: UserDefaults, ruleConfig: RuleConfig) -> String {
        if defaults.object(forKey: "output_lang") != nil {
            return normalizeOutputLanguage(defaults.string(forKey: "output_lang") ?? outputLangSameUI)
        }
        let target = ruleConfig.defaultRule.targetLang.trimmed
        if !target.isEmpty && target.lowercased() != outputLangSameUI && target.lowercased() != "auto" {
            return normalizeOutputLanguage(target)
        }
        if defaults.object(forKey: "pronunciation_lang") != nil {
            return normalizeOutputLanguage(defaults.string(forKey: "pronunciation_lang") ?? outputLangSameUI)
        }
        return outputLangSameUI
    }

    private static func parseRule(source: String, object: [String: Any], fallback: LanguageRule) -> LanguageRule {
        LanguageRule(
            sourceLang: source,
            translationEnabled: object["translation"] as? Bool ?? fallback.translationEnabled,
            pronunciationEnabled: object["pronunciation"] as? Bool ?? fallback.pronunciationEnabled,
            targetLang: object["target"] as? String ?? fallback.targetLang
        )
    }

    private static func ruleJson(_ rule: LanguageRule) -> [String: Any] {
        return [
            "translation": rule.translationEnabled,
            "pronunciation": rule.pronunciationEnabled,
            "target": normalizeOutputLanguage(rule.targetLang)
        ]
    }

    private static func normalizeTargetRules(_ raw: String?) -> String {
        let value = (raw ?? "").trimmed
        return value.isEmpty ? outputLangSameUI : value
    }

    private static func parseTargetRules(_ raw: String?) -> [String: String] {
        let value = (raw ?? "").trimmed
        guard !value.isEmpty, value.range(of: #"[=:]"#, options: .regularExpression) != nil else {
            return [:]
        }
        var rules: [String: String] = [:]
        for entry in value.components(separatedBy: CharacterSet(charactersIn: "\n;,")) {
            let item = entry.trimmed
            guard !item.isEmpty else { continue }
            let colon = item.firstIndex(of: ":")
            let equals = item.firstIndex(of: "=")
            let split: String.Index?
            if let colon, let equals {
                split = colon < equals ? colon : equals
            } else {
                split = colon ?? equals
            }
            guard let split, split > item.startIndex else { continue }
            let after = item.index(after: split)
            guard after < item.endIndex else { continue }
            let source = normalizeSourceLanguageKey(String(item[..<split]))
            let target = normalizeOutputLanguage(String(item[after...]))
            if !source.isEmpty && !target.isEmpty {
                rules[source] = target
            }
        }
        return rules
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            let trimmed = (value ?? "").trimmed
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    private static func backgroundSettingsJson(_ settings: BackgroundSettings) -> [String: Any] {
        let safe = BackgroundSettings(
            mode: settings.mode,
            brightness: settings.brightness,
            blur: settings.blur,
            noise: settings.noise,
            reduceMotion: settings.reduceMotion,
            solidColor: settings.solidColor,
            videoScale: settings.videoScale
        )
        return [
            "mode": safe.mode,
            "brightness": safe.brightness,
            "blur": safe.blur,
            "noise": safe.noise,
            "reduceMotion": safe.reduceMotion,
            "solidColor": safe.solidColor,
            "videoScale": safe.videoScale
        ]
    }

    private static func backgroundSettings(from object: [String: Any], fallback: BackgroundSettings) -> BackgroundSettings {
        BackgroundSettings(
            mode: object["mode"] as? String ?? fallback.mode,
            brightness: object["brightness"] as? Int ?? fallback.brightness,
            blur: object["blur"] as? Int ?? fallback.blur,
            noise: object["noise"] as? Bool ?? fallback.noise,
            reduceMotion: object["reduceMotion"] as? Bool ?? fallback.reduceMotion,
            solidColor: object["solidColor"] as? String ?? fallback.solidColor,
            videoScale: object["videoScale"] as? Int ?? fallback.videoScale
        )
    }

    struct Snapshot: Sendable {
        var uiLang: String
        var outputLang: String
        var provider: Provider
        var defaultRule: LanguageRule
        var languageRules: [String: LanguageRule]
        var translationEnabled: Bool
        var pronunciationEnabled: Bool
        var metadataTranslationEnabled: Bool
        var japaneseFuriganaEnabled: Bool
        var apiKeys: String
        var pollinationsAccessToken: String
        var baseUrl: String
        var model: String
        var maxTokens: Int
        var temperature: Double
        var previewMode: String
        var previewItems: Int
        var autoInstrumentalBreakEnabled: Bool
        var interludeLabelsEnabled: Bool
        var syncedLyricsKaraokeAnimationEnabled: Bool
        var karaokeBounceEffectEnabled: Bool
        var karaokeDataAsLineSynced: Bool
        var useSyncCreatorSpeakerColors: Bool
        var lyricsTextAlignment: String
        var keepScreenOn: Bool
        var landscapeAutoHideControls: Bool
        var landscapeCenterNoLyrics: Bool
        var pipShowArtwork: Bool
        var pipOrientation: String
        var pipBackgroundMode: String
        var pipLyricsTextAlignment: String
        var pipLyricsSizePercent: Int
        var pipTranslationSizePercent: Int
        var backgroundMode: String
        var backgroundBrightness: Int
        var backgroundBlur: Int
        var backgroundNoiseEnabled: Bool
        var backgroundReduceMotionEnabled: Bool
        var backgroundSolidColor: String
        var backgroundVideoScale: Int
        var typography: TypographySettings
        var speakerColors: SpeakerColorSettings
        var spotifyClientId: String
        var spotifyClientSecret: String
        var lyricsProviderOrder: [String]
        var lyricsProviderEnabled: [String: Bool]
        var lyricsProviderTypes: [String: [String: Bool]]
        var preferSyncDataProvider: Bool
        var preferLyricsTypeOverProviderOrder: Bool

        var hasApiKey: Bool {
            if provider.id == "pollinations", !pollinationsAccessToken.trimmed.isEmpty {
                return true
            }
            return !apiKeys.trimmed.isEmpty
        }

        var hasSpotifyCredentials: Bool {
            !spotifyClientId.trimmed.isEmpty && !spotifyClientSecret.trimmed.isEmpty
        }

        var hasSpotifyClientId: Bool {
            !spotifyClientId.trimmed.isEmpty
        }

        var enabledLyricsProviderOrder: [String] {
            AppSettings.normalizedLyricsProviderOrder(lyricsProviderOrder).filter {
                lyricsProviderEnabled[$0] ?? true
            }
        }

        func isLyricsTypeEnabled(providerId: String, type: String) -> Bool {
            lyricsProviderTypes[providerId]?[type] ?? true
        }

        var lyricsProviderPolicySignature: String {
            let providers = AppSettings.normalizedLyricsProviderOrder(lyricsProviderOrder).map { providerId in
                let enabled = lyricsProviderEnabled[providerId] ?? true
                let karaoke = isLyricsTypeEnabled(providerId: providerId, type: AppSettings.lyricsTypeKaraoke)
                let synced = isLyricsTypeEnabled(providerId: providerId, type: AppSettings.lyricsTypeSynced)
                let plain = isLyricsTypeEnabled(providerId: providerId, type: AppSettings.lyricsTypePlain)
                return "\(providerId):\(enabled ? 1 : 0):\(karaoke ? 1 : 0)\(synced ? 1 : 0)\(plain ? 1 : 0)"
            }.joined(separator: ",")
            return "provider-policy-v1|\(preferSyncDataProvider ? 1 : 0)|\(preferLyricsTypeOverProviderOrder ? 1 : 0)|\(providers)"
        }

        var enabled: Bool {
            if japaneseFuriganaEnabled || defaultRule.enabled {
                return true
            }
            return languageRules.values.contains { $0.enabled }
        }

        var targetLanguage: String {
            resolveTargetLanguage(sourceLang: AppSettings.defaultSourceLang)
        }

        var pronunciationLanguage: String {
            AppSettings.resolveOutputLanguage(outputLang, uiLang: uiLang)
        }

        func ruleForSource(_ sourceLang: String) -> LanguageRule {
            let source = AppSettings.normalizeSourceLanguageKey(sourceLang)
            if let rule = languageRules[source] {
                return rule
            }
            if let dash = source.firstIndex(of: "-") {
                let base = String(source[..<dash])
                if let rule = languageRules[base] {
                    return rule
                }
            }
            return LanguageRule(
                sourceLang: source,
                translationEnabled: defaultRule.translationEnabled,
                pronunciationEnabled: defaultRule.pronunciationEnabled,
                targetLang: defaultRule.targetLang
            )
        }

        func resolveTargetLanguage(sourceLang: String) -> String {
            AppSettings.resolveOutputLanguage(defaultRule.targetLang, uiLang: uiLang)
        }

        func shouldSkipTranslation(sourceLang: String, resolvedTargetLang: String) -> Bool {
            ruleForSource(sourceLang).translationEnabled && AppSettings.isSameLanguage(sourceLang, resolvedTargetLang)
        }

        var cacheKey: String {
            var key = "\(provider.id)|output=\(outputLang)|resolvedOutput=\(pronunciationLanguage)|translationTarget=\(defaultRule.targetLang)|default=\(defaultRule.cacheKey)|furigana=\(japaneseFuriganaEnabled)|model=\(model)|url=\(baseUrl)|tok=\(maxTokens)|temp=\(temperature)"
            for rule in languageRules.values.sorted(by: { $0.sourceLang < $1.sourceLang }) {
                key += "|rule=\(rule.cacheKey)"
            }
            return key
        }
    }

    struct LanguageRule: Hashable, Sendable {
        var sourceLang: String
        var translationEnabled: Bool
        var pronunciationEnabled: Bool
        var targetLang: String

        init(sourceLang: String, translationEnabled: Bool, pronunciationEnabled: Bool, targetLang: String) {
            self.sourceLang = AppSettings.normalizeSourceLanguageKey(sourceLang)
            self.translationEnabled = translationEnabled
            self.pronunciationEnabled = pronunciationEnabled
            self.targetLang = AppSettings.normalizeOutputLanguage(targetLang)
        }

        var enabled: Bool {
            translationEnabled || pronunciationEnabled
        }

        var cacheKey: String {
            "\(sourceLang):t=\(translationEnabled):p=\(pronunciationEnabled)"
        }
    }

    private struct RuleConfig {
        var defaultRule: LanguageRule
        var languageRules: [String: LanguageRule]

        func withTarget(_ targetLang: String) -> RuleConfig {
            let target = AppSettings.normalizeOutputLanguage(targetLang)
            let nextDefault = LanguageRule(
                sourceLang: defaultRule.sourceLang,
                translationEnabled: defaultRule.translationEnabled,
                pronunciationEnabled: defaultRule.pronunciationEnabled,
                targetLang: target
            )
            var nextRules: [String: LanguageRule] = [:]
            for (key, rule) in languageRules {
                nextRules[key] = LanguageRule(
                    sourceLang: rule.sourceLang,
                    translationEnabled: rule.translationEnabled,
                    pronunciationEnabled: rule.pronunciationEnabled,
                    targetLang: target
                )
            }
            return RuleConfig(defaultRule: nextDefault, languageRules: nextRules)
        }
    }

    struct BackgroundSettings: Hashable, Sendable {
        var mode: String
        var brightness: Int
        var blur: Int
        var noise: Bool
        var reduceMotion: Bool
        var solidColor: String
        var videoScale: Int

        init(mode: String, brightness: Int, blur: Int, noise: Bool, reduceMotion: Bool, solidColor: String, videoScale: Int) {
            self.mode = AppSettings.normalizeBackgroundMode(mode)
            self.brightness = min(100, max(0, brightness))
            self.blur = min(100, max(0, blur))
            self.noise = noise
            self.reduceMotion = reduceMotion
            self.solidColor = AppSettings.normalizeHexColor(solidColor, fallback: "#1e3a8a")
            self.videoScale = AppSettings.clampBackgroundVideoScale(videoScale)
        }
    }

    struct TypographySlot: Identifiable, Hashable, Sendable {
        var id: String
        var label: String
        var defaultSizePercent: Int
        var defaultWeight: String

        init(id: String, label: String, defaultSizePercent: Int, defaultWeight: String) {
            self.id = id
            self.label = label
            self.defaultSizePercent = min(160, max(70, defaultSizePercent))
            self.defaultWeight = AppSettings.normalizeTypographyWeight(defaultWeight)
        }

        var defaultStyle: TypographyStyle {
            TypographyStyle(sizePercent: defaultSizePercent, weight: defaultWeight, slot: self)
        }
    }

    struct TypographyStyle: Hashable, Sendable {
        var sizePercent: Int
        var weight: String

        init(sizePercent: Int, weight: String, slot: TypographySlot? = nil) {
            let fallbackSize = slot?.defaultSizePercent ?? 100
            let fallbackWeight = slot?.defaultWeight ?? AppSettings.typoWeightSemibold
            self.sizePercent = min(160, max(70, sizePercent <= 0 ? fallbackSize : sizePercent))
            self.weight = AppSettings.normalizeTypographyWeight(weight, fallback: fallbackWeight)
        }

        var scale: Double {
            Double(sizePercent) / 100.0
        }
    }

    struct TypographySettings: Hashable, Sendable {
        var styles: [String: TypographyStyle]

        init(styles: [String: TypographyStyle]) {
            var values: [String: TypographyStyle] = [:]
            for slot in AppSettings.allTypographySlots {
                if let style = styles[slot.id] {
                    values[slot.id] = TypographyStyle(sizePercent: style.sizePercent, weight: style.weight, slot: slot)
                } else {
                    values[slot.id] = slot.defaultStyle
                }
            }
            self.styles = values
        }

        static var defaults: TypographySettings {
            TypographySettings(styles: [:])
        }

        func style(_ slotId: String) -> TypographyStyle {
            let slot = AppSettings.typographySlotById(slotId)
            return styles[slot.id] ?? slot.defaultStyle
        }

        var forVinylPreview: TypographySettings {
            var values = styles
            values[AppSettings.typoMainPreviewOriginal] = style(AppSettings.typoVinylOriginal)
            values[AppSettings.typoMainPreviewPronunciation] = style(AppSettings.typoVinylPronunciation)
            values[AppSettings.typoMainPreviewTranslation] = style(AppSettings.typoVinylTranslation)
            return TypographySettings(styles: values)
        }
    }

    struct SpeakerColorSlot: Identifiable, Hashable, Sendable {
        var id: String
        var label: String
        var defaultColor: String

        init(id: String, label: String, defaultColor: String) {
            self.id = id
            self.label = label
            self.defaultColor = AppSettings.normalizeHexColor(defaultColor, fallback: "#ffffff")
        }
    }

    struct SpeakerColorSettings: Hashable, Sendable {
        var colors: [String: String]

        init(colors: [String: String]) {
            var values: [String: String] = [:]
            for slot in AppSettings.speakerColorSlots {
                values[slot.id] = AppSettings.normalizeHexColor(colors[slot.id] ?? "", fallback: slot.defaultColor)
            }
            self.colors = values
        }

        static var defaults: SpeakerColorSettings {
            SpeakerColorSettings(colors: [:])
        }

        func hex(_ slotId: String) -> String {
            let slot = AppSettings.speakerColorSlotById(slotId)
            return AppSettings.normalizeHexColor(colors[slot.id] ?? "", fallback: slot.defaultColor)
        }
    }

    struct Provider: Identifiable, Hashable, Sendable {
        var id: String
        var label: String
        var description: String
        var defaultBaseUrl: String
        var defaultModel: String
        var apiKeyURL: String
    }

    struct LyricsProvider: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var author: String
        var projectURL: String? = nil
        var defaultEnabled: Bool = true
        var supportsNativeKaraoke: Bool
        var supportsIvLyricsSync: Bool
        var supportsSynced: Bool
        var supportsPlain: Bool
    }

    struct Language: Identifiable, Hashable, Sendable {
        var id: String { code }
        var code: String
        var name: String
        var nativeName: String
        var phoneticDescription: String
    }
}
