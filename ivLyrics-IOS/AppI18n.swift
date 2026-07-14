import Foundation

enum AppI18n {
    static let uiLanguages: [Language] = [
        Language(code: "ko", name: "Korean", nativeName: "한국어"),
        Language(code: "en", name: "English", nativeName: "English"),
        Language(code: "zh-CN", name: "Simplified Chinese", nativeName: "简体中文"),
        Language(code: "zh-TW", name: "Traditional Chinese", nativeName: "繁體中文"),
        Language(code: "ja", name: "Japanese", nativeName: "日本語"),
        Language(code: "hi", name: "Hindi", nativeName: "हिन्दी"),
        Language(code: "es", name: "Spanish", nativeName: "Español"),
        Language(code: "fr", name: "French", nativeName: "Français"),
        Language(code: "ar", name: "Arabic", nativeName: "العربية"),
        Language(code: "fa", name: "Persian", nativeName: "فارسی"),
        Language(code: "de", name: "German", nativeName: "Deutsch"),
        Language(code: "ru", name: "Russian", nativeName: "Русский"),
        Language(code: "sv", name: "Swedish", nativeName: "Svenska"),
        Language(code: "pt", name: "Portuguese", nativeName: "Português"),
        Language(code: "bn", name: "Bengali", nativeName: "বাংলা"),
        Language(code: "cs", name: "Czech", nativeName: "Čeština"),
        Language(code: "it", name: "Italian", nativeName: "Italiano"),
        Language(code: "th", name: "Thai", nativeName: "ภาษาไทย"),
        Language(code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt"),
        Language(code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia"),
        Language(code: "ms", name: "Malay", nativeName: "Bahasa Melayu"),
        Language(code: "tr", name: "Turkish", nativeName: "Türkçe")
    ]

    private static let languageCodeByLowercase = uiLanguages.reduce(into: [String: String]()) { result, language in
        let key = language.code.lowercased()
        if result[key] == nil {
            result[key] = language.code
        }
    }
    private static let canonicalLanguageCodes = Set(uiLanguages.map(\.code))

    private static let androidStrings: [String: [String: String]] = loadBundledStrings()

    private static let iosOverrideKeys: Set<String> = [
        "spotify.step3.desc",
        "spotify.step4.desc"
    ]

    private static let extraStrings: [String: [String: String]] = [
        "ko": [
            "button.close": "닫기",
            "button.previous": "이전",
            "button.save_start": "저장하고 시작",
            "button.next": "다음",
            "button.restart": "처음으로",
            "button.copy": "복사",
            "button.open_browser": "브라우저로 열기",
            "button.done": "완료",
            "button.later": "나중에",
            "button.search": "검색",
            "button.load": "불러오기",
            "button.reload_current": "현재 곡 다시 불러오기",
            "button.clear_current": "현재 곡 삭제",
            "button.clear_all": "전체 삭제",
            "button.reset": "초기화",
            "button.open_release": "릴리즈 페이지 열기",
            "status.idle": "대기 중",
            "status.loaded": "준비됨",
            "status.spotify_track_required": "Spotify 트랙 URL 또는 ID가 필요합니다",
            "status.spotify_metadata_not_found": "Spotify 트랙 메타데이터를 찾지 못했습니다",
            "status.manual_track_required": "제목과 아티스트가 필요합니다",
            "settings.title": "설정",
            "settings.subtitle": "가사, 화면, AI, 도구 설정",
            "tab.lyrics": "가사",
            "tab.display": "화면",
            "tab.ai": "AI",
            "tab.tools": "도구",
            "section.language": "언어",
            "section.language_rules": "언어 규칙",
            "section.spotify_api": "Spotify API",
            "section.update": "업데이트",
            "section.lyrics_cache": "가사 캐시",
            "section.player": "플레이어",
            "section.background": "배경",
            "section.track_background": "현재 곡 배경",
            "section.pip": "Picture in Picture",
            "section.typography": "글자 스타일",
            "section.speaker_colors": "파트 색상",
            "section.ai_lyrics": "가사 AI",
            "section.provider": "제공자",
            "section.lyrics_providers": "가사 제공자",
            "section.lyrics_providers_desc": "가사 제공자를 켜거나 끄고 우선순위와 허용할 가사 유형을 설정합니다.",
            "section.spotify_api_desc": "Client ID는 Spotify App Remote 연결에 사용합니다. Client Secret은 ISRC와 메타데이터 보강을 사용할 때만 선택적으로 입력하며 앱 내부에 저장됩니다.",
            "setting.ui_language": "앱 표시 언어",
            "setting.metadata_translation": "곡 제목/아티스트 번역",
            "setting.auto_interlude": "전주/간주/후주 자동 감지",
            "setting.interlude_labels": "간주 라벨 표시",
            "setting.synced_karaoke_animation": "일반 싱크 가사 노래방 효과",
            "setting.karaoke_bounce_effect": "노래방 튐 효과",
            "setting.karaoke_line_mode": "노래방 데이터를 일반 싱크로 표시",
            "setting.lyrics_type_priority": "가사 유형 우선 조회",
            "setting.lyrics_type_priority_desc": "모든 제공자의 노래방 가사를 먼저 찾은 뒤 싱크 가사, 일반 가사 순서로 조회합니다. 같은 유형 안에서는 설정한 제공자 순서를 따릅니다.",
            "setting.sync_data_provider_priority": "ivLyrics Sync 데이터가 있는 제공자 우선",
            "setting.sync_data_provider_priority_desc": "OpenDB에 현재 곡의 ivLyrics Sync 데이터가 있으면 해당 가사 제공자를 일반 우선순위보다 먼저 시도합니다.",
            "setting.creator_speaker_colors": "싱크 제작자 커스텀 색상 사용",
            "setting.creator_speaker_colors_desc": "싱크 제작자가 데이터에 지정한 보컬 색상을 사용합니다. 끄면 CUSTOM 스피커는 싱크 제작자가 지정한 대체 색상을 사용합니다.",
            "setting.japanese_furigana": "일본어 후리가나",
            "setting.keep_screen_on": "화면 항상 켜기",
            "setting.landscape_auto_hide": "가로모드 컨트롤 자동 숨김",
            "setting.landscape_center_no_lyrics": "가로모드 가사 없음 중앙 정렬",
            "setting.preview_hidden": "하단 가사 숨김",
            "setting.main_preview_original": "원문 표시",
            "setting.main_preview_pronunciation": "발음 표시",
            "setting.main_preview_translation": "번역 표시",
            "setting.pip_show_artwork": "앨범 이미지 표시",
            "setting.pip_lyrics_size": "PiP 가사 크기",
            "setting.background_mode": "배경 효과",
            "setting.brightness": "밝기",
            "setting.blur": "블러",
            "setting.video_scale": "영상 확대",
            "setting.noise": "노이즈 텍스처",
            "setting.reduce_motion": "움직임 줄이기",
            "field.api_key": "API 키",
            "field.model": "모델",
            "field.model_id": "모델 ID 직접 입력",
            "field.model_required": "사용할 모델을 선택하거나 모델 ID를 입력하세요.",
            "status.models_loading": "모델 목록을 불러오는 중…",
            "status.models_unavailable": "모델 목록을 불러오지 못했습니다. 모델 ID를 직접 입력할 수 있습니다.",
            "button.refresh_models": "모델 새로고침",
            "field.base_url": "기본 URL",
            "field.max_tokens": "최대 토큰",
            "field.temperature": "창의성",
            "field.spotify_client_id": "Client ID",
            "field.spotify_client_secret": "Client Secret (선택)",
            "field.title": "제목",
            "field.artist": "아티스트",
            "field.album": "앨범",
            "field.duration_hint": "재생시간 3:42",
            "field.spotify_id": "Spotify ID 또는 URL",
            "field.isrc": "ISRC",
            "field.redirect_uri": "Redirect URI",
            "field.live_source": "Live Source",
            "field.login_code": "로그인 코드",
            "field.output": "출력",
            "field.source": "원본",
            "field.mode": "모드",
            "field.track_language": "곡 언어",
            "field.save_target": "저장 대상",
            "field.alignment": "정렬",
            "field.orientation": "방향",
            "field.lyrics_alignment": "가사 정렬",
            "field.weight": "굵기",
            "lyrics.translation": "번역",
            "lyrics.pronunciation": "발음",
            "lyrics.tab.language": "언어",
            "lyrics.tab.sync": "싱크",
            "lyrics.tab.background": "배경",
            "lyrics.tab.manual": "수동 검색",
            "lyrics.tab.video": "영상",
            "lyrics.rule.track_language": "곡 언어",
            "lyrics.rule.save_target": "저장 대상",
            "lyrics.rule.reset": "이 언어 규칙 초기화",
            "lyrics.sync.title": "현재 곡 싱크 오프셋",
            "lyrics.sync.reset": "0ms로 초기화",
            "lyrics.sync.no_track": "재생 중인 곡이 없으면 저장되지 않습니다.",
            "lyrics.sync.track_scope": "\"%@\"에만 저장됩니다.",
            "lyrics.video_sync.title": "현재 곡 영상 오프셋",
            "lyrics.video_sync.default_detail": "현재 곡 배경 영상",
            "lyrics.bluetooth_sync.title": "Bluetooth 기기 오프셋",
            "lyrics.bluetooth_sync.no_device": "연결된 Bluetooth 오디오 기기가 없습니다.",
            "lyrics.lrclib_search.title": "LRCLIB 수동 검색",
            "lyrics.lrclib_search.field_title": "제목",
            "lyrics.lrclib_search.field_artist": "아티스트",
            "lyrics.lrclib_search.button": "LRCLIB 검색",
            "lyrics.lrclib_search.no_results": "LRCLIB 결과가 없습니다.",
            "lyrics.lrclib_search.synced": "싱크",
            "lyrics.lrclib_search.plain": "일반",
            "lyrics.background.override": "이 곡에만 적용",
            "lyrics.background.reset": "이 곡 배경 초기화",
            "preview.none": "표시안함",
            "preview.original": "원어",
            "preview.pronunciation": "발음",
            "preview.translation": "번역",
            "background.mode.gradient": "앨범 커버",
            "background.mode.blur_gradient": "블러 그라데이션",
            "background.mode.video": "영상",
            "background.mode.solid": "단색",
            "pip.orientation.landscape": "가로",
            "pip.orientation.portrait": "세로",
            "pip.orientation.square": "정사각형",
            "typography.weight.regular": "Regular",
            "typography.weight.semibold": "Semibold",
            "typography.weight.bold": "Bold",
            "alignment.left": "왼쪽",
            "alignment.center": "가운데",
            "alignment.right": "오른쪽",
            "spotify.live.title": "Spotify Live",
            "spotify.live.desc_ios": "iOS 공개 API는 다른 앱의 전역 Now Playing 제목과 아티스트를 읽을 수 없습니다. ivLyrics iOS는 Spotify App Remote를 먼저 사용하고, 실패하면 Spotify Web API 현재 재생 정보로 전환합니다.",
            "spotify.live.connect": "Spotify Live 연결",
            "spotify.live.connected": "Spotify Live 연결됨",
            "spotify.live.stop": "Spotify Live 중지",
            "spotify.live.connect_after_client": "다음 단계에서 Spotify Client ID를 입력한 뒤 연결할 수 있습니다.",
            "toast.spotify_client_id_missing": "Spotify Client ID를 입력하세요.",
            "spotify.api.title": "Spotify API",
            "spotify.api.desc_ios": "Client ID만으로 설치된 Spotify 앱의 App Remote를 연결할 수 있습니다. Client Secret은 ISRC 검색과 메타데이터 보강을 위한 선택 항목입니다.",
            "spotify.status_app_remote_ready": "Client ID 저장됨 · App Remote 사용 가능",
            "spotify.status_configured": "Spotify API 등록 완료",
            "spotify.status_required": "처음 사용 전에 Spotify API 정보를 등록하세요.",
            "spotify.status_checking": "Spotify 토큰 발급 확인 중...",
            "spotify.status_credentials_saved": "Spotify Client ID가 저장되었습니다.",
            "spotify.status_credentials_required": "Client ID가 필요합니다. Client Secret은 선택 항목입니다.",
            "spotify.validate": "Spotify API 정보 확인",
            "spotify.validate_checking": "Spotify API 확인 중...",
            "spotify.disconnect_oauth": "Spotify OAuth 연결 해제",
            "spotify.setup.instructions": "Spotify API 등록 안내",
            "spotify.step0.title": "Spotify 개발자 대시보드로 이동",
            "spotify.step0.desc": "브라우저에서 Spotify Developer Dashboard를 여세요. 계정 로그인 후 앱을 새로 만들면 됩니다.",
            "spotify.step1.title": "Create app에서 이름 입력",
            "spotify.step1.desc": "Create app을 누른 뒤 App name에는 아래 값을 그대로 넣으세요. ivLyrics 또는 ivlyrics라고 적지 마세요.",
            "spotify.step2.title": "설명 입력",
            "spotify.step2.desc": "App description에도 아래 값을 그대로 넣으세요. 이 값은 의미 있는 값이 아니라 헷갈리지 않기 위한 예시입니다.",
            "spotify.step3.title": "Redirect URI 입력",
            "spotify.step3.desc": "Redirect URIs 항목에 아래 iOS 콜백 주소를 추가하세요.",
            "spotify.step4.title": "API 선택 후 저장",
            "spotify.step4.desc": "API/SDK 선택 영역에서 iOS를 선택하고 번들 ID를 저장하세요. Web API는 App Remote 실패 시 보조 경로가 필요할 때만 추가합니다.",
            "spotify.step5.title": "Client ID 복사",
            "spotify.step5.desc": "생성된 앱의 Settings에서 Client ID를 복사하세요. Client Secret은 ISRC와 메타데이터 보강이 필요할 때만 선택적으로 입력합니다.",
            "spotify.copy.dashboard_url": "Dashboard URL",
            "spotify.copy.app_name": "App name",
            "spotify.copy.app_description": "App description",
            "spotify.copy.redirect_uri": "Redirect URI",
            "toast.copied_format": "복사됨: %@",
            "spotify.source.app_remote": "Spotify App Remote",
            "spotify.source.web_api": "Spotify Web API",
            "spotify.source.off": "꺼짐",
            "pollinations.access_token": "Pollinations access token",
            "pollinations.open_login": "로그인 페이지 열기",
            "pollinations.test": "Pollinations 연결 테스트",
            "pollinations.disconnect": "Pollinations 연결 해제",
            "pollinations.sign_in": "Pollinations 로그인",
            "pollinations.reconnect": "Pollinations 다시 연결",
            "update.check": "업데이트 확인",
            "update.checking": "업데이트 확인 중...",
            "update.available.title": "업데이트 가능",
            "update.new_version": "새 버전",
            "update.current": "현재",
            "update.latest": "최신",
            "update.release": "릴리즈",
            "update.prerelease": "Prerelease",
            "update.release_notes": "릴리즈 노트",
            "update.no_release_notes": "릴리스 노트가 없습니다",
            "tmi.title": "TMI",
            "tmi.loading": "TMI 생성 중",
            "tmi.did_you_know": "알고 있었나요?",
            "tmi.verified_sources": "검증된 출처",
            "tmi.related_sources": "관련 출처",
            "tmi.other_sources": "기타 출처",
            "tmi.no_data": "이 곡에 대한 TMI가 아직 없습니다.",
            "tmi.regenerate": "다시 생성",
            "tmi.error_fetch": "TMI를 불러오는 중 오류가 발생했습니다.",
            "tmi.require_key": "AI 제공자 API 키가 필요합니다.",
            "tmi.confidence_format": "신뢰도: %s",
            "onboarding.welcome_title": "ivLyrics 설정 시작",
            "onboarding.subtitle_ios": "Spotify 재생 정보에 맞춰 가사와 싱크를 자동으로 불러옵니다.",
            "onboarding.step_format": "Step %d / %d",
            "onboarding.preview.line1": "노래방 가사가 곡을 따라갑니다",
            "onboarding.preview.line2": "발음과 번역이 여기에 표시됩니다",
            "onboarding.preview.line3": "현재 곡에 맞춰 자동으로 갱신됩니다",
            "onboarding.preview.line4": "제목이나 아티스트를 탭하면 Spotify로 돌아갑니다.",
            "language.same_as_ui": "앱 언어와 동일",
            "language.auto_default": "자동 / 기본값",
            "label.no_current_track": "현재 곡 없음",
            "label.no_bluetooth_output": "Bluetooth 출력 없음",
            "label.unknown": "알 수 없음",
            "label.on": "켜짐",
            "label.off": "꺼짐",
            "label.spotify": "Spotify",
            "label.regenerate": "다시 생성",
            "label.close_pip": "PiP 닫기",
            "pip.simulator_unavailable": "시뮬레이터에서는 시스템 PiP를 사용할 수 없습니다. 실기기에서 확인해 주세요.",
            "label.lyrics_settings": "가사 설정",
            "label.open_lrclib_list": "LRCLIB 목록 열기",
            "label.sync_by": "sync by",
            "lyrics.provider.author_default": "제작자 · default",
            "lyrics.provider.enabled": "이 제공자 사용",
            "lyrics.provider.allowed_types": "허용할 가사 유형",
            "lyrics.provider.type_karaoke": "노래방 가사",
            "lyrics.provider.type_karaoke_sync_data": "노래방 가사 (ivLyrics Sync 데이터)",
            "lyrics.provider.type_synced": "싱크 가사",
            "lyrics.provider.type_plain": "일반 가사",
            "lyrics.provider.open_project": "제공자 페이지 열기"
        ],
        "en": [
            "button.close": "Close",
            "button.previous": "Back",
            "button.save_start": "Save and Start",
            "button.next": "Next",
            "button.restart": "Start Over",
            "button.copy": "Copy",
            "button.open_browser": "Open Browser",
            "button.done": "Done",
            "button.later": "Later",
            "button.search": "Search",
            "button.load": "Load",
            "button.reload_current": "Reload Current Track",
            "button.clear_current": "Clear Current",
            "button.clear_all": "Clear All",
            "button.reset": "Reset",
            "button.open_release": "Open Release Page",
            "status.idle": "Idle",
            "status.loaded": "Ready",
            "status.spotify_track_required": "Spotify track URL or ID is required",
            "status.spotify_metadata_not_found": "Spotify track metadata was not found",
            "status.manual_track_required": "Title and artist are required",
            "settings.title": "Settings",
            "settings.subtitle": "Lyrics, display, AI, and tools",
            "tab.lyrics": "Lyrics",
            "tab.display": "Display",
            "tab.ai": "AI",
            "tab.tools": "Tools",
            "section.language": "Language",
            "section.language_rules": "Language Rules",
            "section.spotify_api": "Spotify API",
            "section.update": "Update",
            "section.lyrics_cache": "Lyrics Cache",
            "section.player": "Player",
            "section.background": "Background",
            "section.track_background": "Current Track Background",
            "section.pip": "Picture in Picture",
            "section.typography": "Typography",
            "section.speaker_colors": "Speaker Colors",
            "section.ai_lyrics": "Lyrics AI",
            "section.provider": "Provider",
            "section.lyrics_providers": "Lyrics Providers",
            "section.lyrics_providers_desc": "Enable, reorder, and choose the allowed lyric types for each provider.",
            "section.spotify_api_desc": "The Client ID connects Spotify App Remote. The optional Client Secret enables ISRC and metadata enrichment and is stored only on this device.",
            "setting.ui_language": "App Language",
            "setting.metadata_translation": "Translate title/artist",
            "setting.auto_interlude": "Auto detect intro/interlude/outro",
            "setting.interlude_labels": "Show interlude labels",
            "setting.synced_karaoke_animation": "Line-synced karaoke effect",
            "setting.karaoke_bounce_effect": "Karaoke bounce effect",
            "setting.karaoke_line_mode": "Treat karaoke data as line-synced",
            "setting.lyrics_type_priority": "Prioritize lyrics type over provider order",
            "setting.lyrics_type_priority_desc": "Try karaoke lyrics across all providers first, then synced lyrics, then plain lyrics. The configured provider order is preserved within each type.",
            "setting.sync_data_provider_priority": "Prioritize providers with ivLyrics Sync data",
            "setting.sync_data_provider_priority_desc": "When OpenDB has ivLyrics Sync data for the current track, try its matching lyrics provider before the normal provider order.",
            "setting.creator_speaker_colors": "Use sync creator custom colors",
            "setting.creator_speaker_colors_desc": "Use custom speaker colors embedded by sync creators. When disabled, CUSTOM speakers use the fallback selected by the sync creator.",
            "setting.japanese_furigana": "Japanese Furigana",
            "setting.keep_screen_on": "Keep Screen On",
            "setting.landscape_auto_hide": "Auto-hide landscape controls",
            "setting.landscape_center_no_lyrics": "Center no lyrics in landscape",
            "setting.preview_hidden": "Preview hidden",
            "setting.main_preview_original": "Preview original",
            "setting.main_preview_pronunciation": "Preview pronunciation",
            "setting.main_preview_translation": "Preview translation",
            "setting.pip_show_artwork": "Show album artwork",
            "setting.pip_lyrics_size": "PiP lyric size",
            "setting.background_mode": "Background effect",
            "setting.brightness": "Brightness",
            "setting.blur": "Blur",
            "setting.video_scale": "Video zoom",
            "setting.noise": "Noise texture",
            "setting.reduce_motion": "Reduce motion",
            "field.api_key": "API Key",
            "field.model": "Model",
            "field.model_id": "Enter model ID",
            "field.model_required": "Select a model or enter its model ID.",
            "status.models_loading": "Loading model list…",
            "status.models_unavailable": "Could not load the model list. You can enter a model ID directly.",
            "button.refresh_models": "Refresh models",
            "field.base_url": "Base URL",
            "field.max_tokens": "Max tokens",
            "field.temperature": "Creativity",
            "field.spotify_client_id": "Client ID",
            "field.spotify_client_secret": "Client Secret (Optional)",
            "field.title": "Title",
            "field.artist": "Artist",
            "field.album": "Album",
            "field.duration_hint": "Duration 3:42",
            "field.spotify_id": "Spotify ID or URL",
            "field.isrc": "ISRC",
            "field.redirect_uri": "Redirect URI",
            "field.live_source": "Live Source",
            "field.login_code": "Login Code",
            "field.output": "Output",
            "field.source": "Source",
            "field.mode": "Mode",
            "field.track_language": "Track Language",
            "field.save_target": "Save Target",
            "field.alignment": "Alignment",
            "field.orientation": "Orientation",
            "field.lyrics_alignment": "Lyrics Alignment",
            "field.weight": "Weight",
            "lyrics.translation": "Translation",
            "lyrics.pronunciation": "Pronunciation",
            "lyrics.tab.language": "Language",
            "lyrics.tab.sync": "Sync",
            "lyrics.tab.background": "Background",
            "lyrics.tab.manual": "Manual Search",
            "lyrics.tab.video": "Video",
            "lyrics.rule.track_language": "Song language",
            "lyrics.rule.save_target": "Save target",
            "lyrics.rule.reset": "Reset Source Rule",
            "lyrics.sync.title": "Current Song Sync Offset",
            "lyrics.sync.reset": "Reset to 0ms",
            "lyrics.sync.no_track": "No playing song, so this will not be saved.",
            "lyrics.sync.track_scope": "Saved only for \"%@\".",
            "lyrics.video_sync.title": "Current Song Video Offset",
            "lyrics.video_sync.default_detail": "Current track background video",
            "lyrics.bluetooth_sync.title": "Bluetooth Device Offset",
            "lyrics.bluetooth_sync.no_device": "No Bluetooth audio device is connected.",
            "lyrics.lrclib_search.title": "Manual LRCLIB Search",
            "lyrics.lrclib_search.field_title": "Title",
            "lyrics.lrclib_search.field_artist": "Artist",
            "lyrics.lrclib_search.button": "Search LRCLIB",
            "lyrics.lrclib_search.no_results": "No LRCLIB results.",
            "lyrics.lrclib_search.synced": "Synced",
            "lyrics.lrclib_search.plain": "Plain",
            "lyrics.background.override": "Apply only to this track",
            "lyrics.background.reset": "Reset This Track Background",
            "preview.none": "Hidden",
            "preview.original": "Original",
            "preview.pronunciation": "Pronunciation",
            "preview.translation": "Translation",
            "background.mode.gradient": "Album Cover",
            "background.mode.blur_gradient": "Blurred Gradient",
            "background.mode.video": "Video",
            "background.mode.solid": "Solid Color",
            "pip.orientation.landscape": "Landscape",
            "pip.orientation.portrait": "Portrait",
            "pip.orientation.square": "Square",
            "typography.weight.regular": "Regular",
            "typography.weight.semibold": "Semibold",
            "typography.weight.bold": "Bold",
            "alignment.left": "Left",
            "alignment.center": "Center",
            "alignment.right": "Right",
            "spotify.live.title": "Spotify Live",
            "spotify.live.desc_ios": "iOS public APIs cannot read the global Now Playing title and artist from other apps. ivLyrics iOS uses Spotify App Remote first and falls back to Spotify Web API current playback when it cannot connect.",
            "spotify.live.connect": "Connect Spotify Live",
            "spotify.live.connected": "Spotify Live Connected",
            "spotify.live.stop": "Stop Spotify Live",
            "spotify.live.connect_after_client": "You can connect after entering a Spotify Client ID in the next step.",
            "toast.spotify_client_id_missing": "Enter a Spotify Client ID.",
            "spotify.api.title": "Spotify API",
            "spotify.api.desc_ios": "A Client ID is enough to connect the installed Spotify app through App Remote. The Client Secret is optional and only improves ISRC and metadata enrichment.",
            "spotify.status_app_remote_ready": "Client ID saved · App Remote ready",
            "spotify.status_configured": "Spotify API configured",
            "spotify.status_required": "Register Spotify API before first use.",
            "spotify.status_checking": "Checking Spotify token...",
            "spotify.status_credentials_saved": "Spotify Client ID saved.",
            "spotify.status_credentials_required": "A Client ID is required. The Client Secret is optional.",
            "spotify.validate": "Validate Spotify API Credentials",
            "spotify.validate_checking": "Checking Spotify API...",
            "spotify.disconnect_oauth": "Disconnect Spotify OAuth",
            "spotify.setup.instructions": "Spotify API setup instructions",
            "spotify.step0.title": "Go to Spotify Developer Dashboard",
            "spotify.step0.desc": "Open Spotify Developer Dashboard in your browser. Sign in and create a new app.",
            "spotify.step1.title": "Enter a name in Create app",
            "spotify.step1.desc": "Press Create app and enter the value below for App name. Do not write ivLyrics or ivlyrics.",
            "spotify.step2.title": "Enter the description",
            "spotify.step2.desc": "Enter the value below for App description too. It is just an example to avoid confusion.",
            "spotify.step3.title": "Enter Redirect URI",
            "spotify.step3.desc": "Add the iOS callback URL below to Redirect URIs.",
            "spotify.step4.title": "Select APIs and save",
            "spotify.step4.desc": "Select iOS under APIs/SDKs and save the bundle ID. Add Web API only if you want the fallback when App Remote is unavailable.",
            "spotify.step5.title": "Copy the Client ID",
            "spotify.step5.desc": "Copy the Client ID from the app settings. Add the Client Secret only if you want ISRC and metadata enrichment.",
            "spotify.copy.dashboard_url": "Dashboard URL",
            "spotify.copy.app_name": "App name",
            "spotify.copy.app_description": "App description",
            "spotify.copy.redirect_uri": "Redirect URI",
            "toast.copied_format": "Copied: %@",
            "spotify.source.app_remote": "Spotify App Remote",
            "spotify.source.web_api": "Spotify Web API",
            "spotify.source.off": "Off",
            "pollinations.access_token": "Pollinations access token",
            "pollinations.open_login": "Open Login Page",
            "pollinations.test": "Test Pollinations Connection",
            "pollinations.disconnect": "Disconnect Pollinations",
            "pollinations.sign_in": "Sign in to Pollinations",
            "pollinations.reconnect": "Reconnect Pollinations",
            "update.check": "Check for Updates",
            "update.checking": "Checking Updates...",
            "update.available.title": "Update Available",
            "update.new_version": "New Version",
            "update.current": "Current",
            "update.latest": "Latest",
            "update.release": "Release",
            "update.prerelease": "Prerelease",
            "update.release_notes": "Release Notes",
            "update.no_release_notes": "No release notes",
            "tmi.title": "TMI",
            "tmi.loading": "Generating TMI",
            "tmi.did_you_know": "Did you know?",
            "tmi.verified_sources": "Verified sources",
            "tmi.related_sources": "Related sources",
            "tmi.other_sources": "Other sources",
            "tmi.no_data": "No TMI is available for this song yet.",
            "tmi.regenerate": "Regenerate",
            "tmi.error_fetch": "Failed to load TMI.",
            "tmi.require_key": "An AI provider API key is required.",
            "tmi.confidence_format": "Confidence: %s",
            "onboarding.welcome_title": "Set Up ivLyrics",
            "onboarding.subtitle_ios": "Lyrics and sync data load automatically from your Spotify playback.",
            "onboarding.step_format": "Step %d / %d",
            "onboarding.preview.line1": "Karaoke lyrics follow the song",
            "onboarding.preview.line2": "Pronunciation and translation appear here",
            "onboarding.preview.line3": "Everything updates with the current track",
            "onboarding.preview.line4": "Tap the title or artist to jump back to Spotify.",
            "language.same_as_ui": "Same as UI",
            "language.auto_default": "Auto / Default",
            "label.no_current_track": "No current track",
            "label.no_bluetooth_output": "No Bluetooth output",
            "label.unknown": "Unknown",
            "label.on": "On",
            "label.off": "Off",
            "label.spotify": "Spotify",
            "label.regenerate": "Regenerate",
            "label.close_pip": "Close PiP",
            "pip.simulator_unavailable": "System PiP is unavailable in the Simulator. Please check it on a physical device.",
            "label.lyrics_settings": "Lyrics settings",
            "label.open_lrclib_list": "Open LRCLIB list",
            "label.sync_by": "sync by",
            "lyrics.provider.author_default": "Author · default",
            "lyrics.provider.enabled": "Enable this provider",
            "lyrics.provider.allowed_types": "Allowed Lyrics Types",
            "lyrics.provider.type_karaoke": "Karaoke Lyrics",
            "lyrics.provider.type_karaoke_sync_data": "Karaoke Lyrics (ivLyrics Sync data)",
            "lyrics.provider.type_synced": "Synced Lyrics",
            "lyrics.provider.type_plain": "Plain Lyrics",
            "lyrics.provider.open_project": "Open provider page"
        ]
    ]

    static func normalize(_ lang: String?) -> String {
        if let lang, canonicalLanguageCodes.contains(lang) {
            return lang
        }
        let value = (lang ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "en" }
        let lower = value.replacingOccurrences(of: "_", with: "-").lowercased()
        switch lower {
        case "jp":
            return "ja"
        case "kr":
            return "ko"
        case "cn", "zh-sg":
            return "zh-CN"
        case "tw", "hk", "zh-hk":
            return "zh-TW"
        case "ko", "ko-kr":
            return "ko"
        case "zh-cn", "zh-hans", "zh":
            return "zh-CN"
        case "zh-tw", "zh-hant":
            return "zh-TW"
        default:
            if let code = languageCodeByLowercase[lower] {
                return code
            }
            let base = lower.split(separator: "-").first.map(String.init) ?? lower
            return languageCodeByLowercase[base] ?? "en"
        }
    }

    static func supports(_ lang: String?) -> Bool {
        let normalized = normalize(lang)
        return uiLanguages.contains { $0.code == normalized }
    }

    static func label(_ lang: String?) -> String {
        let normalized = normalize(lang)
        let language = uiLanguages.first { $0.code == normalized } ?? uiLanguages[1]
        return "\(language.nativeName) · \(language.name)"
    }

    static func t(_ lang: String?, _ key: String) -> String {
        let normalized = normalize(lang)
        if iosOverrideKeys.contains(key) {
            if let value = extraStrings[normalized]?[key] {
                return value
            }
            if let value = extraStrings["en"]?[key] {
                return value
            }
        }
        if let value = androidStrings[normalized]?[key] {
            return value
        }
        if let value = extraStrings[normalized]?[key] {
            return value
        }
        if let value = androidStrings["en"]?[key] {
            return value
        }
        if let value = extraStrings["en"]?[key] {
            return value
        }
        return key
    }

    static func format(_ lang: String?, _ key: String, _ arguments: [CVarArg]) -> String {
        String(format: swiftFormatPattern(t(lang, key)), locale: Locale(identifier: normalize(lang)), arguments: arguments)
    }

    private static func swiftFormatPattern(_ pattern: String) -> String {
        let conversionCharacters = Set("diuoxXfFeEgGaAcCsSp@")
        var result = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            guard character == "%" else {
                result.append(character)
                index = pattern.index(after: index)
                continue
            }

            result.append(character)
            index = pattern.index(after: index)
            guard index < pattern.endIndex else { break }
            if pattern[index] == "%" {
                result.append(pattern[index])
                index = pattern.index(after: index)
                continue
            }

            while index < pattern.endIndex {
                let current = pattern[index]
                if conversionCharacters.contains(current) {
                    result.append(current == "s" ? "@" : current)
                    index = pattern.index(after: index)
                    break
                }
                result.append(current)
                index = pattern.index(after: index)
            }
        }
        return result
    }

    struct Language: Identifiable, Hashable, Sendable {
        var code: String
        var name: String
        var nativeName: String

        var id: String { code }
    }

    private static func loadBundledStrings() -> [String: [String: String]] {
        guard let url = Bundle.main.url(forResource: "AppI18nStrings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return [:]
        }
        return object
    }
}
