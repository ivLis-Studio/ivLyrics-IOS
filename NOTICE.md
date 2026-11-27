# ivLyrics for iOS: license notices

Copyright (c) 2026 ivLis Studio and contributors.

Unless this notice says otherwise, the files in this repository are licensed under the ivLyrics Source-Available License 1.0 in [LICENSE](LICENSE).

## Contributed code

Code that oneulddu contributed through pull requests remains the copyright of its author and is included as contributed to this repository.

## Generated motion lyrics page

`ivLyrics-IOS/Resources/MotionLyricsPage.html` is generated from [ivLyrics for PC](https://github.com/ivLis-Studio/ivLyrics). Do not edit it directly. It contains:

- Code from the PC files `LyricsWordSegmenter.js` and `style.css`, which are licensed under the GNU Lesser General Public License v2.1 as listed in the PC repository's [NOTICE.md](https://github.com/ivLis-Studio/ivLyrics/blob/main/NOTICE.md). The full text is in [LICENSES/LGPL-2.1.txt](LICENSES/LGPL-2.1.txt). You may use, modify, and redistribute that code under the LGPL.
- TinySegmenter (BSD-3-Clause) and Preact (MIT). Their notices are kept inside the file.

## Third-party components

| Component | License | Where |
|---|---|---|
| [Pretendard](https://github.com/orioncactus/pretendard) by Kil Hyung-jin | SIL Open Font License 1.1 | `ivLyrics-IOS/Resources/Fonts/`, notice in [Pretendard-OFL.txt](ivLyrics-IOS/Resources/Fonts/Pretendard-OFL.txt) |
| [TinySegmenter](http://chasen.org/~taku/software/TinySegmenter/) by Taku Kudo, Swift port | BSD-3-Clause | `ivLyrics-IOS/TinySegmenter.swift`, notice in [TinySegmenter.LICENSE.txt](ivLyrics-IOS/TinySegmenter.LICENSE.txt) |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) b11364 | MIT | Downloaded at build time as a binary framework; see [Packages/LlamaCpp](Packages/LlamaCpp/README.md) |
| [pronunciation-lab](https://github.com/ivLis-Studio/pronunciation-lab) | GPL-3.0 | Not included in the app or this repository. When the Pronunciation Lab provider is used, `ivLyrics-IOS/Resources/PronunciationLabPage.html` (generated from ivLyrics for PC) downloads the newest release and its dictionaries from jsDelivr at run time |

## Lyrics and other content

The repository does not contain lyrics, recordings, artwork, or videos, and no license here covers them. ivLyrics retrieves lyrics and other content from third-party services at the user's request; that content belongs to its rights holders. Section 5 of [LICENSE](LICENSE) has the full terms. Rights holders can request removal of content stored on ivLyrics servers at me@ivl.is.

ivLyrics is not affiliated with Spotify. Spotify is a trademark of Spotify AB.
