> [!IMPORTANT]
> IPA files on GitHub Releases are unsigned. They must be signed with your Apple ID through AltStore or another signing tool before installation.

<img width="1122" height="1402" alt="image" src="https://github.com/user-attachments/assets/4e0850bf-092f-45d3-8645-4ed9f1b4dfba" />

# ivLyrics iOS

[한국어](README.md) | English

ivLyrics iOS detects the song currently playing in Spotify and displays karaoke-style lyrics on iOS using ivLyrics community sync data and LRCLIB lyrics.

## Disclaimer

> ⚠️ Disclaimer
>
> **Unofficial Project Notice**
>
> This project and its contributors are not affiliated with, authorized by, endorsed by, or officially connected to Spotify, its affiliates, or its subsidiaries. **This project is an independent, non-profit, unofficial iOS app under development by a volunteer team to provide the ivLyrics experience on iOS.**
>
> **Trademark Notice**
>
> The name "Spotify" and all related names, marks, emblems, and images are registered trademarks of their respective owners. These trademarks are used only for identification and reference, and their use does not imply any association with the trademark owner. This project does not intend to infringe those trademarks or harm their owners.
>
> **Limitation of Liability**
>
> This application is provided "as is" and is used entirely at your own risk. The developers and contributors are not liable for any claims, damages, legal consequences, or other liability arising from the use of this software or related dealings. You are solely responsible for all consequences resulting from your use of this software.
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
- Open Spotify from the current track
- Clear lyric cache for the current track or all tracks

## Installation

ivLyrics iOS supports iOS 17 or later. The Spotify app and Spotify API configuration are required after installation.

### Install with AltStore

AltStore source URL:

```text
https://raw.githubusercontent.com/ivLis-Studio/ivLyrics-IOS/main/altstore-source.json
```

1. Install [AltServer](https://altstore.io/) on a computer, then follow the [macOS guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) or [Windows guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) to install AltStore Classic on your iPhone.
2. Keep the iPhone and the computer running AltServer on the same Wi-Fi network, or connect them by USB.
3. Open the `Sources` tab in AltStore, tap `+`, and add the source URL above.
4. Select ivLyrics from the source and install it.
5. Apps signed with a free Apple ID must be refreshed through AltServer every seven days.

AltStore setup can vary by operating system, Apple ID, Developer Mode, and network configuration. Check the [official AltStore troubleshooting guide](https://faq.altstore.io/altstore-classic/troubleshooting-guide) first. If the issue remains, search the exact error message on the internet.

The latest unsigned IPA can also be downloaded directly from [GitHub Releases](https://github.com/ivLis-Studio/ivLyrics-IOS/releases/latest).

### Run with Xcode

1. Clone this repository.
2. Open `ivLyrics-IOS.xcodeproj` in Xcode.
3. Configure your developer account, bundle ID, and Spotify API settings for your local environment.
4. Run the app on a simulator or iOS device.

## Lyrics Page Tips

- Tap the title or artist once to open Spotify.
- Long-press the title/artist area on the main screen or lyrics page to open lyric settings.
- Tap a lyric line to jump to that position.
- Drag the progress bar to seek.
- If the timing feels off, adjust the sync offset from the lyric settings menu.
- If LRCLIB selected the wrong result, use manual LRCLIB search from the same menu.

## Translation, Pronunciation, and Furigana

ivLyrics iOS detects the song language automatically and stores translation and pronunciation settings separately for each language.

For example, you can enable both translation and pronunciation for Japanese songs, enable only translation for English songs, and disable both for Spanish songs. If the detected language is wrong, you can override it from the lyric settings menu.

Japanese songs can also show furigana above kanji when the option is enabled.

Translation and pronunciation data is cached. Once generated, it stays available after restarting the app. You can clear the cache for the current track or for all tracks from Settings.

## Troubleshooting

### The track is not detected

- Make sure Spotify is actually playing music.
- Make sure Spotify account linking is complete in ivLyrics iOS.
- Open Spotify again and restart playback.

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

### Opening Spotify does not work

- Make sure the Spotify app is installed on iOS.
- Make sure Spotify is actually playing music.
- If track information has not loaded yet, wait briefly and try again.
