# ivLyrics Spotify iOS — development preview 0.2.0

Spotify IPA에 삽입할 수 있는 ivLyrics `.deb` 모듈입니다. **Spotify 9.1.60
(빌드 916001969)의 복호화 바이너리를 정적으로 분석해 구현한 개발판이며,
실제 iPhone에서 설치·실행한 결과는 아직 없습니다.** 최신 Spotify 전체에
호환되는 정식 배포판으로 표시하지 않습니다.

## 구현한 기능

- Spotify의 현재 곡·재생 위치·일시정지 상태를 가사 코드에 전달합니다.
- 기존 ivLyrics 앱의 가사 저장소와 공급자 구현을 직접 빌드합니다. 기본 조회는
  LRCLIB와 LyricsPlus이며, ISRC가 전달되는 곡은 기존 ivSync 처리를 사용합니다.
  LRCLIB 과부하 대응과 LyricsPlus 미러 동시 조회 개선도 같은 원본 코드를 사용합니다.
- 가사를 받으면 Spotify 가사 카드·전체 가사 화면에 ivLyrics를 표시합니다.
  줄/단어 타이밍, 자동 스크롤, 가사 줄을 눌러 탐색하는 기능이 포함됩니다.
  전체 화면에서는 가사 전용 영역만 교체해 Spotify의 닫기·재생 버튼을 유지합니다.
  조회 중이거나 가사가 없으면 Spotify 원래 콘텐츠의 숨김 상태를 복원합니다.
- 재생 화면의 `ivLyrics` 버튼으로 별도 가사 창을 열 수 있습니다. 이 경로에서는
  Spotify 자체 가사가 없는 곡에도 LRC/TXT 파일을 추가할 수 있습니다.
- 가사 창의 더보기 메뉴에서 파일을 가져오거나 가져온 가사를 삭제합니다.
  UTF-8/UTF-16, 최대 1 MiB이며 곡별로 저장합니다. 파일 선택 중 곡이 바뀌어도
  처음 선택한 곡에 연결합니다. 삭제하면 온라인 공급자를 다시 조회합니다.

지원 확인은 실행 파일명, 버전·빌드, 실제 분석한 Objective-C 메서드의 타입을
모두 검사한 후 진행합니다. 하나라도 맞지 않으면 후크를 설치하지 않습니다.
SideStore가 재서명하면서 번들 ID를 변경하는 경우는 허용합니다. 다른 Spotify
버전에 숫자만 바꿔 적용하지 말고 해당 바이너리 분석과 검증을 먼저 해야 합니다.

현재 모듈은 **가사 조회·표시·파일 가져오기**에 집중합니다. 독립 앱의 설정 화면,
번역·발음 변환, Local AI, 계정 로그인 기능은 포함하지 않습니다. 호스트의 계정
정보나 토큰을 읽지 않습니다. 가져온 파일과 캐시도 별도 ivLyricsSpotify 공간에
저장되므로 독립 ivLyrics 앱의 데이터와 공유되지 않습니다.

## 설치 흐름

1. 분석 대상과 일치하는 **복호화 Spotify IPA**와 이 모듈의 `.deb`를 준비합니다.
2. [Sideloadly](https://sideloadly.io/)의 Tweak Injection에 `.deb`를 추가하고
   수정된 IPA를 내보냅니다.
3. [SideStore](https://docs.sidestore.io/docs/faq.html)에서 그 IPA를 다시 서명하고
   설치합니다. iOS 17 이상이 필요합니다.

SideStore는 최종 IPA를 설치하는 단계입니다. `.deb`만 SideStore에 넣어 설치하는
방식은 아닙니다. 이 저장소와 패키지는 Spotify 실행 파일, 인증서, 서명 키를 포함하지
않습니다. 빌드의 임시 ad-hoc 서명은 iPhone 설치용 서명을 대신하지 않습니다.

## 검증 범위

- 대상 IPA의 버전, arm64/iPhoneOS, `cryptid=0`, 필요한 클래스·메서드 ABI를 확인했습니다.
- 합성 호스트로 원래 메서드 호출 보존, 지원하지 않는 호스트의 비활성화,
  재생 정보 변환, 탐색, Spotify 자식 뷰의 숨김 상태 복원을 검사합니다.
- 실제 공유 저장소·공급자 코드에 오프라인 입력과 로컬 HTTP fixture를 사용합니다.
- 별도 시뮬레이터 앱으로 모듈 UI와 파일 가져오기 상태 전환을 검사합니다.
- arm64 dylib와 Debian 아카이브의 구조, 의존성, 서명을 검사합니다.

**이 검사는 실제 Spotify에서의 실행을 증명하지 않습니다.** Xcode 시뮬레이터는
실기기용 Spotify IPA를 그대로 실행할 수 없습니다. 테스터가 iPhone에서 최종 IPA
설치, 로그인, 곡 전환, 일시정지·탐색, 카드/전체 화면, 파일 선택기 왕복을 확인해야
합니다. 특히 호스트 재생 시간의 단위와 화면 배치는 실제 기기 확인이 남아 있습니다.

분석 대상과 타입 정보는 [compatibility/9.1.60.json](compatibility/9.1.60.json)에
기록합니다. 다운로드 파일은 제3자 공개 자료이며 원본 무변조를 보증하지 않습니다.

## 개발

```sh
python3 spotify-tweak/Core/check_core.py
python3 spotify-tweak/Core/check_repository.py
python3 spotify-tweak/tools/check_host_hooks.py
python3 spotify-tweak/scripts/test_packaging.py
python3 spotify-tweak/tools/test_inspect_ipa.py
python3 spotify-tweak/scripts/build_deb.py --allow-unverified
```

패키지는 `spotify-tweak/packaging/out/ivlyrics-spotify-preview_0.2.0_iphoneos-arm.deb`에
생성됩니다. `--allow-unverified`는 미검증 개발 빌드를 명시하는 옵션이며 실제 호환성
검증을 대신하지 않습니다. CI도 정식 릴리스로 자동 업로드하지 않습니다.

- [공통 가사 코드와 오프라인 검사](Core/README.md)
- [패키지 빌드와 검사](packaging/README.md)
- [UI 및 시뮬레이터 검사](UI/README.md)
- [읽기 전용 IPA 검사](tools/README.md)
- `src/SpotifyHost.m`: 버전/ABI 검사와 Spotify 연결
- `UI/`: 모듈 가사 화면, `UI/Harness/`: 별도 합성 시뮬레이터 앱

## English

This is an **unverified development preview**, statically targeted at Spotify
9.1.60 (916001969), iOS 17+. It implements guarded playback observation, a lyrics
card/fullscreen view, line seeking, and per-song LRC/TXT import using the existing
ivLyrics repository. Unsupported versions retain their original behavior.

Use **decrypted Spotify IPA + DEB → Sideloadly injection/export → SideStore
re-sign/install**. This repository distributes no Spotify binary. Static analysis,
synthetic-host tests, simulator UI checks and package validation do not establish
real Spotify launch/playback compatibility. A physical iPhone test is still required.
