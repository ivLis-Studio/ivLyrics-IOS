# ivLyrics Spotify iOS module — development preparation

> **아직 Spotify에서 사용할 수 있는 패치가 아닙니다.** 공유 가사 코드와
> 주입용 패키지의 빌드 기반을 준비한 단계입니다. 대상 Spotify IPA를 분석한
> 재생 정보 연결부와 가사 화면 교체는 아직 구현하지 않았습니다. 개발 빌드를
> 로드해도 Spotify에 후크를 설치하거나 화면을 변경하지 않습니다.

## 목표 설치 흐름

1. 사용자가 준비한 **복호화 Spotify IPA**와 이 프로젝트의 주입용 `.deb`를
   Sideloadly의 Tweak Injection에 넣습니다.
2. 수정된 IPA를 내보냅니다.
3. 해당 IPA를 SideStore에서 다시 서명하고 설치합니다.

[Sideloadly](https://sideloadly.io/)는 `.deb`/`.dylib` 삽입과 수정 IPA 내보내기를
지원합니다. [SideStore](https://docs.sidestore.io/docs/faq.html)는 IPA를 재서명하고
설치하는 단계입니다. SideStore에 `.deb`만 설치하는 방식은 아닙니다. 이 저장소는
Spotify IPA, 계정 정보, 인증서 또는 서명 키를 포함하지 않습니다.

## 현재 준비한 범위

- 기존 앱의 가사 모델, LRC 파서, 로컬 파일 저장소, LyricsPlus 전송 코드를 원본
  파일 경로로 직접 빌드합니다. 독립 앱의 진입점이나 Spotify App Remote는 포함하지 않습니다.
- `IVLyricsSpotifyBridge`는 외부 연결부가 명시적으로 전달한 곡의 가사를 조회하고
  LRC/TXT를 저장·삭제하는 Objective-C 인터페이스입니다. 네트워크는 조회 호출마다
  선택해야 하며, 단순히 라이브러리를 로드하는 것만으로는 요청하지 않습니다.
- 저장소는 호스트 앱 컨테이너의 `Application Support/ivLyricsSpotify/LocalLyrics`
  아래입니다. 독립 ivLyrics 앱의 가져온 파일과 공유되지 않습니다.
- arm64/iPhoneOS 17 이상용 dylib와 주입 도구에서 읽을 수 있는 `.deb`를 검증합니다.
  Substrate나 탈옥 경로의 런타임 라이브러리를 요구하지 않습니다.

현재 모듈에는 **Spotify 내부 재생 연결, 가사 화면, LRCLIB·ivSync·번역·Local AI가
연결되어 있지 않습니다.** 기능이 동작하는 완성 패치나 호환 Spotify 버전 목록으로
배포하면 안 됩니다. 기존 독립 앱과 해당 앱의 릴리스는 이 개발 패키지와 별개입니다.

## 호스트 연결을 마무리하려면

대상 Spotify의 버전·빌드 번호와 복호화 IPA가 필요합니다. 실제 파일의 내부 클래스와
메서드를 확인한 뒤 연결부를 구현하고, 지원 버전을 벗어나면 원래 Spotify 화면을
유지하도록 해야 합니다. 코드에 추측한 private 클래스 이름을 넣지 않습니다.

기기 없이 확인할 수 있는 것은 패키지·Mach-O 구조, 컴파일, 합성 호스트 입력에 대한
가사 처리입니다. Xcode 시뮬레이터는 실기기용 Spotify IPA를 그대로 실행하지 못합니다.
최종 IPA 설치, 로그인, 곡 전환, 일시정지·탐색, 가사 화면과 파일 선택기 왕복은
실제 iPhone의 테스트 결과가 필요합니다. 기기가 없는 개발자는 이후 테스터에게
검증을 요청할 수 있지만, 그 전에는 실제 동작을 확인했다고 표시할 수 없습니다.

## 개발 안내

- [공통 가사 코드와 오프라인 검사](Core/README.md)
- `src/Runtime.swift`: JSON 입력과 Objective-C 인터페이스
- `src/Bootstrap.m`: 후크를 설치하지 않는 개발용 진입점
- [개발 패키지 빌드와 구조 검사](packaging/README.md)
- [IPA 메타데이터·바이너리 검사](tools/README.md): IPA를 수정하거나 추출하지 않습니다.

저장소 루트에서 다음 명령으로 개발 코드를 검사할 수 있습니다.

```sh
python3 spotify-tweak/Core/check_core.py
python3 spotify-tweak/scripts/test_packaging.py
python3 spotify-tweak/tools/test_inspect_ipa.py
python3 spotify-tweak/scripts/build_deb.py --allow-unverified
```

대상 IPA를 준비한 뒤에는 다음 명령으로 버전과 바이너리 정보를 확인합니다.
이 검사는 파일을 복호화하거나 수정하지 않으며, 후크 호환성을 판정하지 않습니다.

```sh
python3 spotify-tweak/tools/inspect_ipa.py /path/to/Spotify.ipa
```

패키징은 기본적으로 중단되며 개발자가 `--allow-unverified`를 명시한 경우에만
미검증 개발 산출물을 생성합니다. 이 옵션은 Spotify 호환성 검증을 대신하지 않습니다.

## English

This is **development infrastructure, not a working Spotify patch**. The current
bootstrap installs no hooks and changes no host UI. It builds the existing lyric
models, LRC parser, local store and LyricsPlus provider directly from their source
files, with an explicit Objective-C bridge for a future version-verified adapter.

The intended user flow is **decrypted Spotify IPA + injection-compatible DEB →
Sideloadly export → SideStore re-sign and install**. Spotify playback integration,
lyric UI and the remaining app features are not connected. A target IPA is required
for implementation, and actual iPhone testing is required before claiming runtime
compatibility. Development artifacts created with `--allow-unverified` must not be
published as a usable release. No Spotify binaries or signing credentials are
included in this repository.
