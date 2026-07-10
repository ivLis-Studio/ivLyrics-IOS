<img width="1122" height="1402" alt="image" src="https://github.com/user-attachments/assets/4e0850bf-092f-45d3-8645-4ed9f1b4dfba" />

# ivLyrics Android

[한국어](README.md) | English

ivLyrics Android detects the song currently playing in Spotify and displays karaoke-style lyrics on Android using ivLyrics community sync data and LRCLIB lyrics.

## Disclaimer

> ⚠️ Disclaimer
>
> **Unofficial Project Notice**
>
> This project and its contributors are not affiliated with, authorized by, endorsed by, or officially connected to Spotify, its affiliates, or its subsidiaries. **This project is an independent, non-profit, unofficial extension developed by a volunteer team to provide a desktop experience.**
>
> **Trademark Notice**
>
> The name "Spotify" and all related names, marks, emblems, and images are registered trademarks of their respective owners. These trademarks are used only for identification and reference, and their use does not imply any association with the trademark owner. This project does not intend to infringe those trademarks or harm their owners.
>
> **Limitation of Liability**
>
> This application (extension) is provided "as is" and is used entirely at your own risk. The developers and contributors are not liable for any claims, damages, legal consequences, or other liability arising from the use of this software or related dealings. You are solely responsible for all consequences resulting from your use of this software.
>
> **Copyright and Terms Compliance**
>
> This project does not claim ownership of, or grant licenses for, lyrics, translations, videos, or any other third-party content. You are responsible for checking and complying with applicable copyright laws, platform policies, API terms of service, and local regulations. You are solely responsible for any storage, reproduction, distribution, transmission, or commercial use made through this project.

## Features

- Direct LRCLIB loading and LRCLIB search fallback
- Character-level fill, bounce animation, and multi-vocal colors
- Original lyrics, pronunciation, translation, and Japanese furigana
- Per-song-language translation and pronunciation rules
- Main player and full lyrics page
- Landscape player with a split lyrics layout
- Floating shortcut from Spotify to ivLyrics
- Clear lyric cache for the current track or all tracks

## Installation

1. Download the latest APK from GitHub Releases.
2. Install the APK on your Android device.
3. If Android shows a security prompt, allow "Install unknown apps" for the app you used to download the APK.
4. Open ivLyrics Android and complete the first-run setup.

You can download the latest APK from [Releases](https://github.com/ivLis-Studio/ivLyrics-Android/releases).

## Lyrics Page Tips

- Tap the title or artist once to open Spotify.
- Long-press the title/artist area on the main screen or lyrics page to open lyric settings.
- Tap a lyric line to jump to that position.
- Drag the progress bar to seek.
- If the timing feels off, adjust the sync offset from the lyric settings menu.
- If LRCLIB selected the wrong result, use manual LRCLIB search from the same menu.

## Translation, Pronunciation, and Furigana

ivLyrics Android detects the song language automatically and stores translation and pronunciation settings separately for each language.

For example, you can enable both translation and pronunciation for Japanese songs, enable only translation for English songs, and disable both for Spanish songs. If the detected language is wrong, you can override it from the lyric settings menu.

Japanese songs can also show furigana above kanji when the option is enabled.

Translation and pronunciation data is cached. Once generated, it stays available after restarting the app. You can clear the cache for the current track or for all tracks from Settings.

## Troubleshooting

### The track is not detected

- Make sure Spotify is actually playing music.
- Make sure notification access is enabled for ivLyrics Android.
- If the Spotify notification is not visible, open Spotify again and restart playback.

### Lyrics or artwork do not load

- Check that your Spotify Client ID and Client Secret are correct.
- Make sure Web API is selected in the Spotify Developer Dashboard.
- Check your internet connection.
- Try saving your Spotify API credentials again from Settings.

### The wrong lyrics were selected

- Long-press the title/artist area on the main screen or lyrics page to open the menu.
- Run manual LRCLIB search.
- Choose the correct lyric result.
- If needed, clear the current track cache and load the track again.

### The lyrics are slightly out of sync

- Adjust sync offset from the lyric settings menu.
- You can fine-tune timing in 10ms, 50ms, and 100ms steps.

### The floating shortcut does not appear

- Make sure display-over-other-apps permission is allowed.
- The shortcut appears only on Spotify's now playing screen.
- It may not appear while Spotify is in the background or on another Spotify screen.
