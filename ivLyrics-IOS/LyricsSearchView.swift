import SwiftUI

/// Lyrics search: ivLyrics without Spotify. A song found by title and artist plays its lyrics
/// on the app's own timer, so the lyrics page, translation and pronunciation work at once.
struct LyricsSearchSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel
    @State private var title = ""
    @State private var artist = ""
    @FocusState private var focusedField: Field?

    /// The fields are not focused on appear: on iPad the page stays visible beside the sheet,
    /// and a keyboard raised by the sheet itself kept the two laying each other out.
    private enum Field { case title, artist }

    private var palette: SettingsPalette { SettingsTheme.palette(settings.settingsTheme) }
    private var canSearch: Bool { !title.trimmed.isEmpty && !artist.trimmed.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(settings.t("lyrics_search.desc"))
                        .font(.subheadline)
                        .foregroundStyle(palette.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("lyrics-search.description")
                    SettingsGroup {
                        SettingsStackRow(title: settings.t("field.title")) {
                            TextField(settings.t("field.title"), text: $title)
                                .textFieldStyle(SettingsTextFieldStyle(palette: palette))
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .submitLabel(.next)
                                .focused($focusedField, equals: .title)
                                .onSubmit { focusedField = .artist }
                                .accessibilityIdentifier("lyrics-search.title")
                        }
                        SettingsStackRow(title: settings.t("field.artist")) {
                            TextField(settings.t("field.artist"), text: $artist)
                                .textFieldStyle(SettingsTextFieldStyle(palette: palette))
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .focused($focusedField, equals: .artist)
                                .onSubmit(search)
                                .accessibilityIdentifier("lyrics-search.artist")
                        }
                    }
                    Button(action: search) {
                        SettingsButtonLabel(title: settings.t("lyrics_search.submit"), systemImage: "music.note.list")
                    }
                    .buttonStyle(SettingsButtonStyle(tone: .primary, fullWidth: true))
                    .disabled(!canSearch)
                    .accessibilityIdentifier("lyrics-search.submit")
                    SettingsGroup(tone: .muted) {
                        SettingsNoteRow(text: settings.t("lyrics_search.timer_note"), systemImage: "timer")
                    }
                    if model.offersLyricsSearch {
                        Button { model.connectSpotifyFromLyricsSearch() } label: {
                            SettingsButtonLabel(title: settings.t("lyrics_search.connect_spotify"), systemImage: "link")
                        }
                        .buttonStyle(SettingsButtonStyle(fullWidth: true))
                        .accessibilityIdentifier("lyrics-search.connect")
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(palette.background.ignoresSafeArea())
            .navigationTitle(settings.t("lyrics_search.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(settings.t("button.close")) { model.lyricsSearchPresented = false }
                        .accessibilityIdentifier("lyrics-search.close")
                }
            }
        }
        .environment(\.settingsPalette, palette)
        .environment(\.colorScheme, palette.colorScheme)
        .preferredColorScheme(palette.colorScheme)
        .onAppear {
            // Searching again starts from the searched song on screen.
            if let track = model.currentTrack, track.isLocalTimeline {
                title = track.title
                artist = track.artist
            }
        }
    }

    private func search() {
        guard canSearch else { return }
        focusedField = nil
        model.searchLyricsWithoutSpotify(title: title, artist: artist)
    }
}

/// The player page while nothing from Spotify is playing: lyrics search or a Spotify connection.
struct LyricsSearchEntryCard: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(settings.t("lyrics_search.empty_title"))
                    .font(.pretendard(17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(settings.t("lyrics_search.empty_desc"))
                    .font(.pretendard(13))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { searchButton; connectButton }
                VStack(spacing: 8) { searchButton; connectButton }
            }
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.09)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("main.lyrics-search-card")
    }

    private var searchButton: some View {
        Button { model.presentLyricsSearch() } label: {
            Label(settings.t("lyrics_search.title"), systemImage: "magnifyingglass")
                .font(.pretendard(15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(.black)
                .background(.white, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("main.lyrics-search")
    }

    private var connectButton: some View {
        Button { model.connectSpotifyOrOpenSetup() } label: {
            Label(settings.t("lyrics_search.connect_spotify"), systemImage: "link")
                .font(.pretendard(15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(.white)
                .background(.white.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("main.connect-spotify")
    }
}
