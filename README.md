<img width="2208" height="512" alt="ivLyrics 한국어 배너" src="https://github.com/ivLis-Studio/ivLyrics/blob/main/preview_readme_ko.png?raw=true" /><br>
PLATFORM : <a href="https://github.com/ivLis-Studio/ivLyrics">ivLyrics (PC)</a> | <a href="https://github.com/ivLis-Studio/ivLyrics-Android">Android</a> | <a href="https://github.com/ivLis-Studio/ivLyrics-IOS">iOS</a><br>
MODULE : <a href="https://github.com/ivLis-Studio/ivLyrics-overlay">Overlay</a> | <a href="https://github.com/ivLis-Studio/ivLyrics-helper">Helper</a>

# ivLyrics iOS

한국어 | [English](README_EN.md)

Spotify로 듣는 음악을 가사와 함께 즐겨 보세요. ivLyrics iOS는 재생 중인 곡에 맞춰 가사를 보여주고, 원하는 언어의 번역과 따라 읽기 위한 발음을 함께 표시하는 앱입니다. iPhone이나 iPad에서 가사를 크게 보거나, 가로 화면·화면 속 화면(PiP)·LP 모드로 감상하고 싶은 분을 위한 앱입니다. 음악 재생은 Spotify가 담당합니다.

[최신 버전 다운로드](https://github.com/ivLis-Studio/ivLyrics-IOS/releases/latest) · [릴리스 내역](https://github.com/ivLis-Studio/ivLyrics-IOS/releases) · [Discord 도움받기](https://discord.gg/2fu36fUzdE)

> [!IMPORTANT]
> 이 저장소의 배포 방식은 GitHub Releases의 **무서명 IPA**와 AltStore 소스입니다. IPA는 AltStore Classic 같은 도구에서 사용자 Apple ID로 서명한 뒤 설치해야 합니다. 이 안내는 App Store나 AltStore PAL 설치 안내가 아닙니다.

## 어떤 가사를 볼 수 있나요?

- ivLyrics 커뮤니티 싱크 데이터와 LRCLIB, Lyrically (Paxsenix), LyricsPlus, Unison 등의 가사 제공자를 사용합니다. 제공자와 조회 순서는 설정에서 선택할 수 있습니다.
- 곡에 있는 데이터에 따라 일반 가사, 줄 단위 싱크, 단어·글자 단위 노래방 가사를 표시합니다. 채워짐 효과, 보컬별 색상과 간주 표시를 조절할 수 있습니다.
- 원어·번역·발음을 따로 켜고, 곡 언어별로 다른 규칙을 저장할 수 있습니다. 일본어 후리가나도 지원합니다.
- 글꼴, 정렬, 배경, 가로 화면, PiP와 LP 화면을 취향에 맞게 바꿀 수 있습니다.

모든 곡에 가사나 정밀 싱크가 있는 것은 아닙니다. 표시되는 가사와 번역의 품질·사용 가능 여부는 원본 데이터, 선택한 제공자와 네트워크 상태에 따라 달라집니다.

## 설치 전에 준비해 주세요

- iOS 17 이상인 iPhone 또는 iPadOS 17 이상인 iPad
- 같은 기기에 설치하고 로그인한 Spotify 앱
- 가사 조회와 온라인 제공자를 위한 인터넷 연결
- IPA 서명에 사용할 Apple ID와 설치 도구. 아래 AltStore Classic 방식은 Mac 또는 Windows 컴퓨터와 AltServer를 사용합니다.
- 본인이 관리하는 [Spotify 개발자 앱](https://developer.spotify.com/dashboard)의 Client ID. Spotify 연결 설정이 필요하므로, 앱 설치만으로 설정이 끝나지는 않습니다.

Spotify 개발자 계정에는 별도의 이용 조건이 적용됩니다. 특히 Web API의 현재 [개발 모드 규정](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)은 앱 소유자의 Spotify Premium과 허용 사용자 등록을 요구합니다. Web API를 사용할 계획이라면 먼저 확인하세요.

## 앱 설치하기

### AltStore Classic으로 설치

<a href="https://intradeus.github.io/http-protocol-redirector?r=altstore://source?url=https://raw.githubusercontent.com/ivLis-Studio/ivLyrics-IOS/main/altstore-source.json">
  <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/AltSource_Blue.png" alt="AltStore에 추가" width="200">
</a>

1. [AltServer](https://altstore.io/)를 받고, 공식 [macOS 안내](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) 또는 [Windows 안내](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)에 따라 기기에 AltStore Classic을 설치하세요. 기기 신뢰와 개발자 모드 설정도 완료하세요.
2. 기기를 AltServer가 실행 중인 컴퓨터와 USB로 연결하거나, 공식 안내에 따라 Wi-Fi 동기화를 설정하세요.
3. 위 버튼으로 소스를 추가하세요. 버튼이 열리지 않으면 AltStore의 소스 추가 화면에 아래 주소를 붙여넣으세요.
4. 추가된 소스에서 ivLyrics를 선택하고 설치하세요.

```text
https://raw.githubusercontent.com/ivLis-Studio/ivLyrics-IOS/main/altstore-source.json
```

무료 Apple ID로 설치한 앱은 [7일 안에 갱신](https://faq.altstore.io/altstore-classic/your-altstore)해야 하며, 활성화할 수 있는 앱 수에도 제한이 있습니다. AltStore에서 만료일을 확인하고 AltServer에 연결해 갱신하세요.

### IPA를 직접 설치

[최신 릴리스](https://github.com/ivLis-Studio/ivLyrics-IOS/releases/latest)의 Assets에서 `ivLyrics-IOS-v<버전>-unsigned.ipa`를 받으세요. `.sha256`과 `-version.json`은 확인용 파일이며 설치 파일은 `.ipa`입니다. 사용 중인 서명 도구의 안내에 따라 서명하고 설치하세요. 다운로드한 IPA를 여는 것만으로 설치되지는 않습니다.

## 첫 곡의 가사 보기

1. Spotify에서 로그인한 뒤 음악을 재생하세요.
2. ivLyrics를 열고 첫 설정에서 화면 언어와 테마를 선택하세요. 기본 연결은 **Spotify App Remote**입니다. **Spotify Web API 사용**은 다음 곡 미리 준비와 보조 재생 정보를 위한 선택 사항입니다.
3. [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)에서 개인용 앱을 등록하고 iOS SDK를 선택하세요. 앱 안의 **Spotify API · 설정** 안내와 [Spotify 공식 iOS 안내](https://developer.spotify.com/documentation/ios/getting-started)를 함께 참고하세요. 이 배포본의 기본 번들 ID는 `kr.ivlis.ivlyrics.ios`, 콜백은 `musicplayer-auth://callback`입니다. 서명 도구가 번들 ID를 바꿨다면 설치된 앱의 실제 값을 등록해야 합니다.
4. 발급받은 **Client ID**를 ivLyrics에 입력하고 **저장하고 시작**을 누르세요. Spotify로 이동하면 연결을 승인하고 ivLyrics로 돌아오세요. **Client Secret은 선택 항목**이며, ISRC와 메타데이터를 보강할 때만 사용합니다.
5. 곡 제목과 아티스트가 표시되면 가사 미리보기를 눌러 전체 가사를 여세요. 앨범 커버를 누르면 LP 모드를 열 수 있습니다.

Web API를 켜면 별도의 Spotify 웹 로그인이 진행됩니다. 꺼도 App Remote로 현재 곡을 따라갈 수 있습니다. 다만 현재 앱의 콜백은 위 사용자 지정 스킴으로 고정되어 있고, Spotify의 [Web API Redirect URI 규정](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri)은 HTTPS를 요구합니다. Dashboard에서 콜백을 거부하거나 웹 인증이 실패하면 임의 주소로 바꾸지 말고 오류를 제보해 주세요. 이 README만으로 해당 연결 제약을 해결할 수는 없습니다.

## 내 LRC 파일로 가사 추가하기

곡을 재생한 뒤 **설정 → 현재 재생 곡 설정 → 가사 제공자 → 가사 파일 불러오기**에서 `.lrc` 또는 `.txt` 파일을 선택하세요. UTF-8 또는 UTF-16로 저장한 1MB 이하의 파일을 지원합니다. LRC의 시간 정보는 줄 단위 싱크에 사용됩니다.

파일은 선택을 시작한 곡에 저장되어 온라인 가사보다 먼저 표시되며, 앱을 다시 열거나 가사 캐시를 지워도 유지됩니다. 같은 메뉴의 **로컬 가사 삭제**를 누르면 온라인 가사를 다시 불러옵니다.

## 번역과 발음 설정하기

**설정 → 일반**에서 번역·발음의 표시와 출력 언어를 정하고, **AI 제공자**에서 사용할 서비스를 켜고 순서를 조절하세요. 켜 둔 제공자가 실패하면 다음 제공자를 시도합니다. 곡 언어별 규칙을 사용하면 일본어 곡은 번역과 발음을, 영어 곡은 번역만 표시하는 식으로 설정할 수 있습니다.

| 사용하고 싶은 기능 | 필요한 설정 |
| --- | --- |
| 가사 뜻 번역 | Bing Translate·Google Translate는 별도 API 키 없이 사용합니다. DeepL은 API 키가 필요합니다. 모두 번역 전용입니다. |
| AI 번역과 발음 생성 | Gemini, OpenAI 호환 API, Claude 등 지원하는 AI 제공자의 연결 정보와 모델을 설정하세요. 발음 생성에는 준비된 AI 제공자가 필요합니다. |
| 기기 안에서 가사 번역 | **Local AI**를 켜고 모델을 받으세요. 번역 전용이므로 발음·곡 제목·아티스트 번역에는 사용하지 않습니다. |
| 일본어 한자 읽기 | 일본어 후리가나 표시를 켜세요. 뜻 번역이나 AI 발음 표시와는 별도입니다. |

Local AI는 기본적으로 꺼져 있습니다. 품질은 **로컬 라이트 / 로컬 미디엄 / 로컬 하이** 중에서 고르며, 모바일 기본값은 라이트입니다. 모델 하나에 약 1.13 / 1.47 / 1.91 GB의 다운로드 공간과 실행 중 추가 메모리가 필요합니다. 고사양 기기에서 사용을 권장하며, 먼저 제공자 설정의 테스트로 동작을 확인하세요. 메모리가 부족하거나 앱이 백그라운드로 이동하면 실행이 중단될 수 있습니다.

### 비용과 데이터는 어떻게 되나요?

온라인 번역·AI 기능은 가사와 요청에 필요한 곡 정보를 해당 서비스로 전송합니다. 제공자의 요금, 할당량과 데이터 처리 정책을 확인하세요. API 키 없이 쓰는 번역도 외부 서비스이며 항상 사용 가능하다는 보장은 없습니다. AI 결과에는 오역이나 잘못된 발음이 있을 수 있습니다.

Local AI를 켜는 것만으로 먼저 사용되지는 않습니다. 로컬 번역을 우선하려면 **AI 제공자에서 Local AI를 온라인 제공자보다 앞에 배치**하세요. 앞에 있는 온라인 제공자는 Local AI보다 먼저 요청을 받을 수 있습니다. **기기 내 번역만 원하면 다른 온라인 번역 제공자를 모두 꺼 주세요.** Local AI의 번역 계산은 기기에서 처리하지만 모델 다운로드, 가사 조회와 다른 온라인 기능에는 인터넷을 사용합니다. 앱 전체의 오프라인 동작이나 외부 전송 차단을 보장하지 않습니다.

생성한 번역과 발음은 캐시됩니다. 설정에서 AI 캐시, 현재 곡 가사 또는 전체 가사 캐시를 지울 수 있습니다. API 키와 계정 정보는 공개하거나 제보 화면에 포함하지 마세요.

## 듣는 동안 편하게 쓰기

- **현재 재생 곡 설정**에서 곡 언어, 가사 제공자, 수동 검색, 싱크와 배경을 확인하세요. 곡 제목·아티스트 영역을 길게 눌러도 곡 설정 메뉴를 열 수 있습니다.
- 가사 줄을 누르거나 재생바를 움직이면 재생 위치를 바꿀 수 있습니다. 실제 제어 가능 여부는 Spotify 연결 상태와 계정의 재생 제한을 따릅니다.
- 곡 제목을 누르는 기본 동작은 Spotify 열기이며, 설정에서 동작을 바꿀 수 있습니다.
- **외관**에서 글꼴·정렬·배경을, **플레이어**에서 가로 화면·PiP·LP 모드를 조절하세요.
- 싱크는 전체 곡·현재 곡·Bluetooth 기기별로 보정할 수 있습니다. 10ms·50ms·100ms 단위로 조절하며, **+는 가사를 더 일찍, −는 더 늦게** 표시합니다.
- Discord 계정을 연결한 월간 후원자는 **고급**에서 iOS 설정을 클라우드에 저장할 수 있습니다. API 키, 계정 정보, 곡별 오프셋과 다운로드한 Local AI 모델은 동기화 대상이 아닙니다.

## 업데이트와 문제 해결

새 버전은 [GitHub Releases](https://github.com/ivLis-Studio/ivLyrics-IOS/releases/latest) 또는 AltStore 소스에서 확인하세요. 앱의 업데이트 확인도 릴리스 정보를 안내하며, IPA 설치에는 다시 서명이 필요합니다. 같은 서명 계정과 앱 식별자를 유지해 업데이트하세요. AltStore의 주기적인 서명 갱신과 새 버전 설치는 별개입니다.

| 이런 문제가 있나요? | 먼저 확인해 주세요 |
| --- | --- |
| 앱을 열 수 없거나 설치가 실패합니다 | IPA 서명·만료일, 개발자 모드, 기기 신뢰와 AltServer 연결을 확인하고 [AltStore 문제 해결](https://faq.altstore.io/altstore-classic/troubleshooting-guide)을 참고하세요. |
| 곡이 표시되지 않습니다 | Spotify에서 실제로 음악을 재생하고, Client ID·번들 ID·콜백 등록과 연결 승인을 확인한 뒤 Spotify 연결을 다시 시도하세요. |
| Web API 연결이 실패합니다 | Dashboard의 허용 사용자와 Premium 조건, 콜백 거부 여부를 확인하세요. Web API를 끄고 App Remote 연결부터 확인할 수 있습니다. |
| 가사가 없거나 다른 곡으로 나옵니다 | 현재 곡 설정에서 가사 제공자나 LRCLIB 수동 검색을 바꾸세요. 필요한 경우 현재 곡 캐시를 지우고 다시 불러오세요. |
| 싱크가 밀립니다 | 현재 곡 오프셋과 Bluetooth 기기 오프셋을 확인하세요. 원본에 정밀 싱크가 없으면 글자 단위 표시에도 한계가 있습니다. |
| 번역만 나오고 발음이 없습니다 | Bing·Google·DeepL·Local AI는 번역 전용입니다. AI 제공자의 키·모델과 해당 곡 언어의 발음 설정을 확인하세요. |
| Local AI가 느리거나 실패합니다 | 라이트 품질로 낮추고, 저장 공간·메모리를 확인하세요. 앱을 전면에 둔 상태에서 제공자 테스트를 실행하세요. |
| 403·429 또는 제공자 오류가 나옵니다 | 계정 권한·사용량 제한을 확인하고 잠시 후 다시 시도하거나 다른 제공자를 선택하세요. |

[Discord](https://discord.gg/2fu36fUzdE)에 앱 버전, 기기·OS, 곡 링크, 사용한 제공자, 재현 순서와 오류 문구를 남겨 주세요. 스크린샷과 로그에서는 API 키·Client Secret·인증 토큰을 가려 주세요.

## 함께 만든 서비스

ivLyrics 커뮤니티의 싱크 제작자와 기여자, [LRCLIB](https://lrclib.net/), Lyrically (Paxsenix), [LyricsPlus](https://github.com/ibratabian17/lyricsplus), [Unison](https://github.com/better-lyrics/unison) 및 번역 제공자에게 감사합니다. 실제 가사 화면의 제공자·제작자 표기도 확인해 주세요. Local AI는 Tencent Hy-MT2와 llama.cpp를 사용합니다. 글꼴과 포함된 라이브러리의 라이선스 고지는 저장소와 앱 리소스에 유지되어 있습니다.

<details>
<summary>개발·빌드·검증 자료</summary>

Xcode에서 `ivLyrics-IOS.xcodeproj`를 열고 서명 계정과 번들 ID를 지정해 기기에서 실행할 수 있습니다. 번들 ID를 변경했다면 Spotify 개발자 앱의 등록도 맞춰 주세요. 배포 IPA를 만드는 과정은 [무서명 IPA 빌드 스크립트](scripts/build-unsigned-ipa.sh)와 [릴리스 워크플로](.github/workflows/ios-unsigned-release.yml)를 참고하세요.

[설정 UI 검증 안내](docs/native-settings-ui-testing.md)와 [검증 스크립트](scripts/)도 제공됩니다. 시뮬레이터는 실제 기기의 Spotify 연결 검증을 대신하지 않습니다. Local AI 엔진의 기기·시뮬레이터 빌드 조건은 [LlamaCpp 안내](Packages/LlamaCpp/README.md)에 정리되어 있습니다.

</details>

## 면책 조항

> **비공식 프로젝트 안내**
>
> 본 프로젝트와 기여자는 Spotify 또는 그 계열사 및 자회사와 제휴, 권한 부여, 승인 또는 공식적인 연결 관계가 없습니다. ivLyrics iOS는 iOS에서 ivLyrics 경험을 제공하기 위해 자원봉사 팀이 개발 중인 독립적이고 비영리적인 비공식 앱입니다.
>
> **상표권 안내**
>
> “Spotify”를 포함한 관련 명칭, 마크, 엠블럼 및 이미지는 해당 소유자의 등록 상표입니다. 식별 및 참조 목적으로 사용하며 상표권자와의 연관성을 시사하지 않습니다. 상표권을 침해하거나 소유자에게 피해를 줄 의도가 없습니다.
>
> **책임의 한계**
>
> 앱은 “있는 그대로(AS IS)” 제공되며 사용에 따른 위험은 사용자에게 있습니다. 개발자와 기여자는 사용 또는 관련 거래로 발생하는 청구, 손해, 법적 결과나 기타 책임을 지지 않으며, 사용 결과에 대한 책임은 사용자에게 있습니다.
>
> **저작권 및 약관 준수**
>
> 본 프로젝트는 가사, 번역문, 영상 등 제3자 콘텐츠의 소유권을 주장하거나 라이선스를 부여하지 않습니다. 사용자는 관련 저작권법, 플랫폼 정책, API 이용약관과 현지 법령을 확인하고 준수해야 하며, 저장·복제·배포·송신·상업적 이용에 대한 책임을 집니다.
