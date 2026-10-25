# ivLyrics Privacy Policy

Effective October 26, 2026 · ivLyrics for iPhone and iPad, by ivLis STUDIO

[한국어](#개인정보-처리방침)

## At a glance

- **No ads, no tracking.** ivLyrics has no analytics, advertising, telemetry or crash-reporting SDKs.
- **No account needed.** Your settings, caches, keys and imported lyrics stay on your device.
- **Song lookups.** To find lyrics, the app sends information about the song you are playing to the lyric services you turn on.

## What stays on your device

- Settings, lyric and translation caches, and lyrics you import, in the app's own storage.
- Your Spotify Client ID and authorization, AI provider API keys and other credentials, in the iOS Keychain.

Deleting the app removes its storage. iOS can keep Keychain entries after an app is deleted, so clear those fields in Settings first if you want them gone. Clearing caches in Settings removes cached lyrics and translations.

## What is sent, and to whom

### Song information for lyrics, timing and videos

While a song plays, the app sends its title, artist, album and length, and for some services its identifiers (the Spotify track ID and ISRC, a code for the recording), to the lyric providers enabled in Settings:

- **ivLyrics services** (lyrics.api.ivl.is and ivlis.kr) for shared sync timing, the OpenDB index and community background videos. Song information may be stored there to serve those features; it is not linked to you.
- **LRCLIB** (lrclib.net), and optionally Paxsenix, Unison, LyricsPlus or a custom LRCLIB server you enter.

Like any internet request, these requests carry your device's IP address. They include no account or advertising identifier.

### Spotify

ivLyrics follows playback in the Spotify app (Spotify App Remote) and, if you turn it on, the Spotify Web API, using the Client ID you create in Spotify's developer dashboard. You authorize with Spotify, and the resulting tokens are kept in your Keychain. Spotify's privacy policy covers your Spotify account.

### Translation, pronunciation and AI features (optional)

When you turn these on, lyrics and song information go from your device directly to the service you choose: free Google or Microsoft (Bing) translation, or an AI provider with your own key, such as OpenAI, Google Gemini, Anthropic, Groq, OpenRouter, Perplexity, DeepL or Pollinations. That provider's privacy policy applies. The on-device AI option runs entirely on your iPhone or iPad; its model is downloaded from Hugging Face.

Song stories send the song's title, artist and album and your language to ivLyrics services, which may use Google Gemini or another AI service to write them. Results may be cached.

### Background videos and links

Music-video backgrounds play in YouTube's embedded player (youtube-nocookie.com); YouTube's privacy policy applies while a video plays. Creator profiles and help pages open in an in-app browser, where those websites' own policies apply.

## Version from GitHub

The version distributed on GitHub can also check GitHub for updates and, optionally, sign in with Discord to manage a sync-creator profile, back up settings and share video timing. Signing in sends your Discord ID, name and picture to ivLyrics services, which store your profile settings, backed-up settings and video submissions. **The App Store version includes neither the update check nor sign-in.**

## Children

ivLyrics is a general-audience music app and does not knowingly collect personal information from children.

## Changes

Changes appear in this file with a new date, and the history is public on GitHub.

## Contact

Questions or requests about privacy: open an issue at [github.com/ivLis-Studio/ivLyrics-IOS/issues](https://github.com/ivLis-Studio/ivLyrics-IOS/issues).

---

# 개인정보 처리방침

시행일 2026년 10월 26일 · ivLis STUDIO의 iPhone·iPad용 ivLyrics

## 한눈에 보기

- **광고·추적 없음.** 분석, 광고, 원격 측정, 충돌 보고 SDK를 쓰지 않아요.
- **계정 필요 없음.** 설정, 캐시, 키, 가져온 가사는 내 기기에 저장돼요.
- **곡 조회.** 가사를 찾기 위해, 켜 둔 가사 서비스에 지금 재생 중인 곡 정보를 보내요.

## 내 기기에 저장되는 것

- 설정, 가사·번역 캐시, 직접 가져온 가사는 앱 저장소에 저장돼요.
- Spotify Client ID와 인증 정보, AI 제공자 API 키 같은 자격 증명은 iOS 키체인에 저장돼요.

앱을 삭제하면 앱 저장소가 지워져요. 키체인 항목은 앱을 삭제해도 iOS에 남을 수 있으니, 지우려면 먼저 설정에서 해당 값을 비워 주세요. 설정에서 캐시를 지우면 저장된 가사와 번역이 지워져요.

## 무엇을 어디로 보내나요

### 가사·싱크·영상을 찾기 위한 곡 정보

곡이 재생되면 곡 제목, 아티스트, 앨범, 길이와, 일부 서비스에는 식별자(Spotify 트랙 ID, 음원 코드인 ISRC)를 설정에서 켜 둔 가사 제공자에게 보내요.

- **ivLyrics 서비스**(lyrics.api.ivl.is, ivlis.kr): 공유 싱크, OpenDB 목록, 커뮤니티 배경 영상에 쓰여요. 이 기능을 제공하려고 곡 정보가 저장될 수 있지만, 사용자와 연결되지 않아요.
- **LRCLIB**(lrclib.net), 그리고 선택에 따라 Paxsenix, Unison, LyricsPlus 또는 직접 입력한 LRCLIB 서버.

모든 인터넷 요청처럼 기기의 IP 주소가 함께 전달돼요. 계정이나 광고 식별자는 보내지 않아요.

### Spotify

ivLyrics는 Spotify 개발자 대시보드에서 직접 만든 Client ID로 Spotify 앱(Spotify App Remote)과, 켠 경우 Spotify Web API에서 재생 정보를 받아요. 인증은 Spotify에서 이뤄지고, 발급된 토큰은 키체인에 저장돼요. Spotify 계정에는 Spotify의 개인정보 처리방침이 적용돼요.

### 번역·발음·AI 기능(선택)

이 기능을 켜면 가사와 곡 정보가 내 기기에서 직접, 내가 고른 서비스로 전송돼요. 무료 Google·Microsoft(Bing) 번역이나, 내 키를 넣은 OpenAI, Google Gemini, Anthropic, Groq, OpenRouter, Perplexity, DeepL, Pollinations 같은 AI 제공자예요. 해당 제공자의 개인정보 처리방침이 적용돼요. 기기 내 AI는 iPhone·iPad 안에서만 실행되며, 모델은 Hugging Face에서 내려받아요.

곡 이야기 기능은 곡 제목, 아티스트, 앨범과 사용 언어를 ivLyrics 서비스에 보내고, 서비스는 Google Gemini 같은 AI 서비스로 내용을 만들 수 있어요. 결과는 캐시될 수 있어요.

### 배경 영상과 링크

뮤직비디오 배경은 YouTube 임베드 플레이어(youtube-nocookie.com)로 재생되며, 재생 중에는 YouTube의 개인정보 처리방침이 적용돼요. 크리에이터 프로필과 도움말은 앱 안의 브라우저로 열리고, 해당 웹사이트의 정책이 적용돼요.

## GitHub 배포 버전

GitHub에서 배포하는 버전은 GitHub에서 업데이트를 확인하고, 선택적으로 Discord로 로그인해 싱크 크리에이터 프로필 관리, 설정 백업, 영상 싱크 공유를 할 수 있어요. 로그인하면 Discord ID, 이름, 프로필 사진이 ivLyrics 서비스로 전달되고, 프로필 설정과 백업한 설정, 영상 제출 내역이 저장돼요. **App Store 버전에는 업데이트 확인과 로그인 기능이 모두 없어요.**

## 어린이

ivLyrics는 전 연령 대상 음악 앱이며, 어린이의 개인정보를 의도적으로 수집하지 않아요.

## 변경

방침이 바뀌면 이 파일에 새 날짜와 함께 반영되고, 변경 내역은 GitHub에 공개돼요.

## 문의

개인정보 관련 문의나 요청은 [github.com/ivLis-Studio/ivLyrics-IOS/issues](https://github.com/ivLis-Studio/ivLyrics-IOS/issues)에 이슈로 남겨 주세요.
