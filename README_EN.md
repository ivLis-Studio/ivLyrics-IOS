<img width="2208" height="512" alt="ivLyrics English banner" src="https://github.com/ivLis-Studio/ivLyrics/blob/main/preview_readme_en.png?raw=true" /><br>
PLATFORM : <a href="https://github.com/ivLis-Studio/ivLyrics">ivLyrics (PC)</a> | <a href="https://github.com/ivLis-Studio/ivLyrics-Android">Android</a> | <a href="https://github.com/ivLis-Studio/ivLyrics-IOS">iOS</a><br>
MODULE : <a href="https://github.com/ivLis-Studio/ivLyrics-overlay">Overlay</a> | <a href="https://github.com/ivLis-Studio/ivLyrics-helper">Helper</a>

# ivLyrics iOS

[한국어](README.md) | English

Follow the music you play in Spotify with lyrics, translations, and pronunciation guides on iPhone or iPad. Read full lyrics, use the landscape layout or Picture in Picture (PiP), or enjoy Vinyl mode. Spotify handles music playback.

[Download the latest release](https://github.com/ivLis-Studio/ivLyrics-IOS/releases/latest) · [Release history](https://github.com/ivLis-Studio/ivLyrics-IOS/releases) · [Help on Discord](https://discord.gg/2fu36fUzdE)

> [!IMPORTANT]
> Releases contain an **unsigned IPA**. Sign it with your Apple ID using a tool such as AltStore Classic before installing it. This repository provides GitHub downloads and an AltStore source; these are not App Store or AltStore PAL installation instructions.

## What can I see?

- Lyrics from LRCLIB, Lyrically (Paxsenix), LyricsPlus, and Unison, with ivLyrics community sync data. Choose providers and their order in Settings.
- Plain, line-synced, or word/character-level karaoke lyrics, depending on the available data, with adjustable fill effects, vocal colors, and instrumental-break labels.
- Separate original lyrics, translations, pronunciation, and Japanese furigana, with rules for each song language.
- Adjustable fonts, alignment, backgrounds, landscape layout, PiP, and Vinyl mode.

Not every song has lyrics or detailed timing. Availability and quality depend on the source data, selected providers, and network connection.

## Before you install

You need iOS 17+ or iPadOS 17+, Spotify installed and signed in on the same device, internet access, and an Apple ID/signing tool. The AltStore Classic route below uses AltServer on a Mac or Windows computer. You also need a Client ID from a [Spotify developer app](https://developer.spotify.com/dashboard) you manage.

Spotify applies its own account restrictions. The current [Web API development-mode rules](https://developer.spotify.com/documentation/web-api/concepts/quota-modes) require the app owner to have Spotify Premium and authenticated users to be allowlisted. Check these before using Web API features.

## Install the app

### Use AltStore Classic

<a href="https://intradeus.github.io/http-protocol-redirector?r=altstore://source?url=https://raw.githubusercontent.com/ivLis-Studio/ivLyrics-IOS/main/altstore-source.json">
  <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/AltSource_Blue.png" alt="Add to AltStore" width="200">
</a>

1. Download [AltServer](https://altstore.io/) and follow the official [macOS](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) or [Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) guide to install AltStore Classic. Complete device trust and Developer Mode setup.
2. Connect your device to the computer running AltServer by USB, or configure Wi-Fi syncing as described in the official guide.
3. Add the source with the button above, or paste the URL below into AltStore's source-add screen. Select ivLyrics and install it.

```text
https://raw.githubusercontent.com/ivLis-Studio/ivLyrics-IOS/main/altstore-source.json
```

With a free Apple ID, apps need [refreshing within seven days](https://faq.altstore.io/altstore-classic/your-altstore), and active sideloaded apps are limited. Check expiry in AltStore and refresh while connected to AltServer.

### Install the IPA yourself

Download `ivLyrics-IOS-v<version>-unsigned.ipa` from the Assets of the [latest release](https://github.com/ivLis-Studio/ivLyrics-IOS/releases/latest). The `.sha256` and `-version.json` files are verification metadata. Follow your signing tool's instructions; opening the IPA alone will not install it.

## See lyrics for your first song

1. Sign in to Spotify and play a song.
2. Open ivLyrics and choose your language and theme. **Spotify App Remote** is the standard connection. **Use Spotify Web API** is optional, for next-song preparation and fallback playback information.
3. Register a personal app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), selecting the iOS SDK. Follow the in-app **Spotify API · Setup** guide and [Spotify's iOS guide](https://developer.spotify.com/documentation/ios/getting-started). This release uses bundle ID `kr.ivlis.ivlyrics.ios` and callback `musicplayer-auth://callback`. If your signing tool changes the bundle ID, register the installed ID instead.
4. Enter your **Client ID**, tap **Save and Start**, and approve the connection when Spotify opens. **Client Secret is optional**, for ISRC and metadata enrichment only.
5. Return to ivLyrics. Once the title and artist appear, tap the lyric preview for full lyrics, or the album cover for Vinyl mode.

Web API starts a separate Spotify web login; App Remote can follow the current song with Web API off. There is a connection constraint: the app uses the fixed custom-scheme callback above, while Spotify's [Web API redirect rules](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri) require HTTPS. If the Dashboard rejects it or web authorization fails, report the error instead of substituting an arbitrary address.

## Translation and pronunciation

In **Settings → General**, choose what to display and the output languages. In **AI Providers**, enable services and set their order. Failed requests try the next enabled provider. Per-language rules let you use translation and pronunciation for Japanese songs but only translation for English songs, for example.

| Feature | Provider setup |
| --- | --- |
| Lyric translation | Bing Translate and Google Translate need no personal API key. DeepL requires an API key. All three are translation-only. |
| AI translation and pronunciation | Configure a supported AI service such as Gemini, an OpenAI-compatible API, or Claude, including its connection and model. Pronunciation needs a configured AI provider. |
| On-device lyric translation | Enable **Local AI** and download a model. It does not generate pronunciation or translate titles and artists. |
| Readings above Japanese kanji | Enable Japanese furigana separately from translation and AI pronunciation. |

Local AI is off by default. **Local Light / Local Medium / Local High** downloads are about 1.13 / 1.47 / 1.91 GB each, with additional memory needed at runtime. Mobile defaults to Light. A powerful device is recommended; run the provider test first. Memory pressure or moving the app to the background can interrupt translation.

### Cost and data use

Online providers receive lyrics and the song information needed for the request. Check their pricing, quotas, and data policies. Keyless services still work online and may become unavailable. Generated translations and pronunciation can be wrong.

**Enabling Local AI does not give it priority. Move it ahead of online providers** to try it first; providers above it can receive the request before Local AI. **For local-only lyric translation, disable all other online translation providers.** Local inference happens on-device, but model downloads, lyric lookup, and other online features still use the internet. This does not guarantee an offline app or prevent all external data transfers.

Translations and pronunciation are cached. Settings lets you clear AI cache, current-song lyrics, or all lyric cache. Never include credentials in public reports.

## While listening

- Open **Current track settings** for song language, provider, manual search, timing, and background settings. Long-pressing the title/artist area also opens the song menu.
- Tap a lyric line or drag the progress bar to seek, subject to Spotify connection and account playback restrictions. Tapping the title opens Spotify by default; the action is configurable.
- Use **Appearance** for fonts, alignment, and backgrounds, and **Player** for landscape, PiP, and Vinyl options.
- Adjust timing globally, per song, or per Bluetooth device in 10ms, 50ms, or 100ms steps. **Positive values show lyrics earlier; negative values show them later.**
- Monthly supporters signed in with Discord can save iOS settings to the cloud under **Advanced**. API keys, account information, per-song offsets, and downloaded Local AI models are excluded.

## Updates and troubleshooting

Check [GitHub Releases](https://github.com/ivLis-Studio/ivLyrics-IOS/releases/latest), the AltStore source, or the in-app update check. New IPAs still need signing. Keep the same signing account and app identifier. AltStore signature refreshes and new-version installation are separate tasks.

| Problem | What to check |
| --- | --- |
| The app will not install or open | Signing, expiry, Developer Mode, device trust, and AltServer connectivity. See [AltStore troubleshooting](https://faq.altstore.io/altstore-classic/troubleshooting-guide). |
| No current song | Start Spotify playback, check Client ID, bundle ID and callback registration, approve the connection, and reconnect. |
| Web API cannot connect | Check Dashboard allowlist, Premium requirements, and callback rejection. Try App Remote with Web API off first. |
| Missing or wrong lyrics | Change providers or use manual LRCLIB search in current-track settings; clear that song's cache if needed. |
| Timing is off | Check song and Bluetooth offsets. Detailed display depends on available timing data. |
| Translation without pronunciation | Bing, Google, DeepL, and Local AI are translation-only. Check AI credentials/model and the pronunciation rule for that song language. |
| Local AI is slow or fails | Try Light quality, check storage/memory, and run the provider test with the app in the foreground. |
| 403, 429, or provider errors | Check account access and usage limits. Wait before retrying or select another provider. |

Ask on [Discord](https://discord.gg/2fu36fUzdE) with the app version, device/OS, song link, provider, reproduction steps, and exact error. Redact API keys, Client Secrets, and authentication tokens from screenshots and logs.

## Credits

Thanks to ivLyrics community sync creators and contributors, [LRCLIB](https://lrclib.net/), Lyrically (Paxsenix), [LyricsPlus](https://github.com/ibratabian17/lyricsplus), [Unison](https://github.com/better-lyrics/unison), and translation providers. Check provider and creator credits on the lyrics screen. Local AI uses Tencent Hy-MT2 and llama.cpp. Font and bundled-library license notices remain in the repository and app resources.

<details>
<summary>Development, builds, and verification</summary>

Open `ivLyrics-IOS.xcodeproj` in Xcode, configure signing and the bundle ID, and run on a device. Update the Spotify developer-app registration if the ID changes. See the [unsigned IPA script](scripts/build-unsigned-ipa.sh), [release workflow](.github/workflows/ios-unsigned-release.yml), [native Settings UI guide](docs/native-settings-ui-testing.md), and [verification scripts](scripts/).

Simulator checks do not establish a working device Spotify connection. The [LlamaCpp README](Packages/LlamaCpp/README.md) explains Local AI device and simulator build requirements.

</details>

## Disclaimer

> **Unofficial project**
>
> This project and its contributors are not affiliated with, authorized by, endorsed by, or officially connected to Spotify, its affiliates, or subsidiaries. ivLyrics iOS is an independent, non-profit, unofficial app under development by a volunteer team to provide the ivLyrics experience on iOS.
>
> **Trademarks**
>
> “Spotify” and related names, marks, emblems, and images are registered trademarks of their respective owners. They are used for identification and reference only and imply no association with their owners. This project does not intend to infringe those trademarks or harm their owners.
>
> **Limitation of liability**
>
> The app is provided “as is” and used at your own risk. Developers and contributors are not liable for claims, damages, legal consequences, or other liability arising from its use or related dealings. You are responsible for the consequences of using it.
>
> **Copyright and terms**
>
> This project does not claim ownership of, or grant licenses for, lyrics, translations, videos, or other third-party content. You must check and comply with applicable copyright laws, platform policies, API terms, and local regulations, and are responsible for storage, reproduction, distribution, transmission, or commercial use through this project.
