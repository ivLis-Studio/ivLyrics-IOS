> [!IMPORTANT]
> GitHub Releases의 IPA는 무서명 파일입니다. AltStore 같은 도구에서 사용자 Apple ID로 서명한 뒤 설치해야 합니다.

<img width="1122" height="1402" alt="image" src="https://github.com/user-attachments/assets/93f24505-a80d-4636-a622-2d8a8ba5f1f8" />

# ivLyrics iOS

한국어 | [English](README_EN.md)

Spotify에서 재생 중인 곡을 감지하고, ivLyrics 커뮤니티 싱크 데이터와 LRCLIB 가사를 이용해 iOS에서 노래방 스타일 가사를 보여주는 앱입니다.

## 면책 조항

> ⚠️ 면책 조항 (Disclaimer)
>
> **비공식 프로젝트 안내**
>
> 본 프로젝트와 기여자는 Spotify, 또는 그 계열사 및 자회사와 어떠한 제휴, 권한 부여, 승인 또는 공식적인 연결 관계도 없음을 밝힙니다. **본 프로젝트는 iOS에서 ivLyrics 경험 제공을 목적으로 자원봉사 팀이 개발 중인 독립적이고 비영리적인 비공식 앱입니다.**
>
> **상표권 안내**
>
> "Spotify"라는 명칭을 포함하여 관련 명칭, 마크, 엠블럼 및 이미지는 해당 소유자의 등록 상표입니다. 이러한 상표의 사용은 식별 및 참조 목적으로만 사용되며, 상표권자와의 어떠한 연관성도 시사하지 않습니다. 본 프로젝트는 해당 상표권을 침해하거나 상표권자에게 피해를 줄 의도가 없음을 명시합니다.
>
> **책임의 한계**
>
> 본 애플리케이션은 "있는 그대로(AS IS)" 제공되며, 사용 시 발생하는 위험은 전적으로 사용자의 책임입니다. 개발자 또는 기여자는 본 소프트웨어의 사용 또는 기타 거래와 관련하여 발생하는 청구, 손해 또는 법적 결과를 포함한 어떠한 책임도 지지 않습니다. 본 소프트웨어 사용으로 인한 모든 결과에 대한 책임은 전적으로 사용자에게 있습니다.
>
> **저작권 및 약관 준수**
>
> 본 프로젝트는 가사, 번역문, 영상 또는 기타 제3자 콘텐츠의 소유권을 주장하지 않으며, 해당 콘텐츠에 대한 라이선스를 부여하지도 않습니다. 사용자는 관련 저작권법, 플랫폼 정책, API 이용약관 및 현지 법령을 직접 확인하고 준수할 책임이 있으며, 본 프로젝트를 이용한 저장, 복제, 배포, 송신 또는 상업적 이용에 대한 책임은 전적으로 사용자에게 있습니다.

## 주요 기능

- LRCLIB 직접 불러오기 및 검색 fallback
- 글자 단위 채워짐, 통통 튀는 애니메이션, 멀티 보컬 색상 표시
- 원어, 발음, 번역, 일본어 후리가나 표시
- 곡 언어별 번역/발음 설정
- 메인 플레이어와 전체 가사 페이지
- 가로 화면 전용 플레이어 + 가사 분할 레이아웃
- 현재 곡에서 Spotify 앱으로 바로 이동
- 현재 곡 또는 전체 곡의 가사 캐시 삭제

## 설치

ivLyrics iOS는 iOS 17 이상을 지원합니다. 설치 후 Spotify 앱과 Spotify API 설정이 필요합니다.

### AltStore로 설치

AltStore 소스 URL:

```text
https://raw.githubusercontent.com/ivLis-Studio/ivLyrics-IOS/main/altstore-source.json
```

1. 컴퓨터에 [AltServer](https://altstore.io/)를 설치하고, [macOS 안내](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) 또는 [Windows 안내](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)에 따라 iPhone에 AltStore Classic을 설치합니다.
2. iPhone과 AltServer가 실행 중인 컴퓨터를 같은 Wi-Fi에 연결하거나 USB로 연결합니다.
3. AltStore의 `Sources` 탭에서 `+`를 누르고 위 소스 URL을 추가합니다.
4. 소스에 표시된 ivLyrics를 선택해 설치합니다.
5. 무료 Apple ID로 서명한 앱은 7일마다 AltServer를 통해 갱신해야 합니다.

AltStore 설치 과정은 OS, Apple ID, 개발자 모드 및 네트워크 환경에 따라 달라질 수 있습니다. 문제가 생기면 [AltStore 공식 문제 해결 문서](https://faq.altstore.io/altstore-classic/troubleshooting-guide)를 먼저 확인하고, 해결되지 않으면 표시되는 오류 문구를 그대로 인터넷에서 검색하세요.

최신 무서명 IPA는 [GitHub Releases](https://github.com/ivLis-Studio/ivLyrics-IOS/releases/latest)에서도 직접 받을 수 있습니다.

### Xcode로 실행

1. 이 저장소를 클론합니다.
2. Xcode에서 `ivLyrics-IOS.xcodeproj`를 엽니다.
3. 개발자 계정, 번들 ID, Spotify API 설정을 로컬 환경에 맞게 지정합니다.
4. 시뮬레이터 또는 iOS 기기에서 실행합니다.

## 가사 페이지 팁

- 곡 제목 또는 아티스트를 한 번 누르면 Spotify 앱으로 이동합니다.
- 메인 화면 또는 가사 페이지에서 곡 제목과 아티스트 영역을 길게 누르면 가사 설정 메뉴가 열립니다.
- 가사를 누르면 해당 위치로 이동합니다.
- 재생바를 드래그하면 원하는 구간으로 이동합니다.
- 싱크가 맞지 않으면 메뉴에서 오프셋을 조절할 수 있습니다.
- LRCLIB 결과가 잘못 잡힌 경우 메뉴에서 수동 검색으로 다른 가사를 선택할 수 있습니다.

## 번역, 발음, 후리가나

ivLyrics iOS는 곡 언어를 자동으로 감지하고, 언어별로 번역과 발음 표시 여부를 따로 저장합니다.

예를 들어 일본어 곡에서는 번역과 발음을 켜고, 영어 곡에서는 번역만 켜고, 스페인어 곡에서는 둘 다 끄는 식으로 사용할 수 있습니다. 자동 감지된 언어가 마음에 들지 않으면 가사 설정 메뉴에서 곡 언어를 직접 바꿀 수 있습니다.

일본어 곡은 옵션을 켜면 한자 위에 후리가나를 표시할 수 있습니다.

번역과 발음 데이터는 캐시됩니다. 한 번 생성된 데이터는 앱을 다시 열어도 유지되며, 필요하면 설정에서 현재 곡 또는 전체 곡의 캐시를 지울 수 있습니다.

## 문제 해결

### 곡이 감지되지 않아요

- Spotify에서 음악이 실제로 재생 중인지 확인하세요.
- ivLyrics iOS에서 Spotify 계정 연결이 완료되었는지 확인하세요.
- Spotify 앱을 다시 열고 재생을 다시 시작해 보세요.

### 가사나 앨범 이미지가 불러와지지 않아요

- Spotify Client ID와 Client Secret이 올바른지 확인하세요.
- Spotify Developer Dashboard에서 Web API를 선택했는지 확인하세요.
- 인터넷 연결을 확인하세요.
- 설정에서 Spotify API 정보를 다시 저장해 보세요.

### 가사가 다른 곡으로 잡혀요

- 메인 화면 또는 가사 페이지에서 곡 제목/아티스트 영역을 길게 눌러 메뉴를 엽니다.
- LRCLIB 수동 검색을 실행합니다.
- 맞는 가사를 선택합니다.
- 필요하면 현재 곡 캐시를 삭제한 뒤 다시 불러오세요.

### 싱크가 조금 밀려요

- 가사 설정 메뉴에서 싱크 오프셋을 조절하세요.
- 10ms, 50ms, 100ms 단위로 미세 조정할 수 있습니다.

### Spotify 열기가 동작하지 않아요

- iOS에 Spotify 앱이 설치되어 있는지 확인하세요.
- Spotify에서 음악이 실제로 재생 중인지 확인하세요.
- 곡 정보가 아직 불러와지지 않았다면 잠시 기다린 뒤 다시 시도하세요.
