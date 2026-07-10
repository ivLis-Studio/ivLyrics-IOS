import Combine
import Foundation

#if os(iOS)
import AVFoundation
import UIKit
#endif

@MainActor
final class AppViewModel: ObservableObject {
    private static let spotifyPlaybackRefreshBurstDelays: [UInt64] = [
        0,
        120_000_000,
        420_000_000,
        1_100_000_000
    ]

    @Published var inputTitle: String
    @Published var inputArtist: String
    @Published var inputAlbum: String
    @Published var inputDuration: String
    @Published var inputSpotifyId: String
    @Published var inputIsrc: String
    @Published private(set) var currentTrack: TrackSnapshot?
    @Published private(set) var lyricsResult = LyricsResult.empty("")
    @Published private(set) var baseLyricsResult = LyricsResult.empty("")
    @Published private(set) var status: AppStatus = .idle
    @Published private(set) var logs: [String] = []
    @Published private(set) var metadataTranslation: AiLyricsRepository.MetadataTranslation?
    @Published var tmiPresented = false
    @Published private(set) var tmiTrack: TrackSnapshot?
    @Published private(set) var tmiInfo: AiLyricsRepository.TmiInfo?
    @Published private(set) var tmiLoading = false
    @Published private(set) var tmiError = ""
    @Published private(set) var youtubeInfo: YouTubeVideoInfo?
    @Published private(set) var manualCandidates: [ManualLrclibCandidate] = []
    @Published private(set) var searchingManualCandidates = false
    @Published private(set) var manualLrclibStatus = ""
    @Published private(set) var resolvingSpotifyMetadata = false
    @Published private(set) var spotifyUserConnected = false
    @Published private(set) var spotifyLivePolling = false
    @Published private(set) var spotifyDeviceName = ""
    @Published private(set) var spotifyAppRemoteConnected = false
    @Published private(set) var spotifyCredentialsValidationInFlight = false
    @Published private(set) var spotifyValidationStatus = ""
    @Published private(set) var bluetoothAudioDeviceName = ""
    @Published private(set) var bluetoothAudioDeviceKey = ""
    @Published private(set) var inAppBrowserURL: URL?
    @Published private(set) var pollinationsAuthInFlight = false
    @Published private(set) var pollinationsAuthStatus = ""
    @Published private(set) var pollinationsAuthUserCode = ""
    @Published private(set) var pollinationsAuthVerificationURL: URL?
    @Published private(set) var updateStatus = ""
    @Published private(set) var toastMessage = ""
    @Published private(set) var updateCheckInFlight = false
    @Published private(set) var aiLyricsGenerating = false
    @Published private(set) var lyricsSupplementPronunciationLoading = false
    @Published private(set) var lyricsSupplementTranslationLoading = false
    @Published private(set) var lyricsSupplementFuriganaLoading = false
    @Published private(set) var lyricsFocusRequestRevision = 0
    @Published var selectedRuleSourceLang = "auto"
    @Published private(set) var pendingUpdateInfo: AppUpdateInfo?
    @Published var updateDialogPresented = false
    @Published var initialSetupPresented = false
    @Published var onboardingStep = 0
    @Published private(set) var nowPositionMs: Int64 = 0
    @Published var trackOffsetMs: Int = 0 {
        didSet {
            let clamped = Self.clampSyncOffset(trackOffsetMs)
            if trackOffsetMs != clamped {
                trackOffsetMs = clamped
                return
            }
            guard let key = currentTrack?.stableKey else { return }
            settings.setTrackSyncOffsetMs(key, trackOffsetMs)
        }
    }
    @Published var videoOffsetMs: Int = 0 {
        didSet {
            let clamped = Self.clampSyncOffset(videoOffsetMs)
            if videoOffsetMs != clamped {
                videoOffsetMs = clamped
                return
            }
            guard let key = currentTrack?.stableKey else { return }
            settings.setTrackVideoSyncOffsetMs(key, videoOffsetMs)
        }
    }
    @Published var bluetoothOffsetMs: Int = 0 {
        didSet {
            let clamped = Self.clampSyncOffset(bluetoothOffsetMs)
            if bluetoothOffsetMs != clamped {
                bluetoothOffsetMs = clamped
                return
            }
            guard !bluetoothAudioDeviceKey.isEmpty else { return }
            settings.setBluetoothSyncOffsetMs(bluetoothAudioDeviceKey, bluetoothOffsetMs)
        }
    }

    let settings: AppSettings
    private let lyricsRepository = LyricsRepository()
    private let aiRepository = AiLyricsRepository()
    private let youtubeRepository = YouTubeBackgroundRepository()
    private let furiganaRepository = FuriganaRepository()
    private let spotifyUserPlaybackService = SpotifyUserPlaybackService()
    private let spotifyAppRemotePlaybackService = SpotifyAppRemotePlaybackService()
    let pictureInPictureController = LyricsPictureInPictureController()
    private let pollinationsAuthClient = PollinationsAuthClient()
    private let updateChecker = UpdateChecker()
    private let creatorProfileEndpoint = "https://lyrics.api.ivl.is/user/creator-profile"
    private let syncDataSpotifyOrigin = "https://xpui.app.spotify.com"
    private let syncDataSpotifyReferer = "https://xpui.app.spotify.com/"
    private var loadTask: Task<Void, Never>?
    private var metadataTranslationTask: Task<Void, Never>?
    private var furiganaRefreshTask: Task<Void, Never>?
    private var manualTask: Task<Void, Never>?
    private var tmiTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var pollinationsAuthTask: Task<Void, Never>?
    private var spotifyPollTask: Task<Void, Never>?
    private var spotifyMetadataHydrationTask: Task<Void, Never>?
    private var spotifyPlaybackRefreshBurstTask: Task<Void, Never>?
    private var youtubeBackgroundLoadTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var timer: Timer?
    private var audioRouteObserver: NSObjectProtocol?
    private var creatorProfileUrlCache: [String: URL] = [:]
    private var spotifyMetadataHydrationTrackId = ""
    private var spotifyHydratedTrackIds: Set<String> = []
    private var currentYouTubeBackgroundRequestKey = ""
    private var currentYouTubeBackgroundLoading = false
    private var currentTmiRequestKey = ""
    private var currentFuriganaKey = ""
    private var currentFuriganaResult: LyricsResult?
    private var lastSeekCommandUptimeMs: Int64 = 0
    private var lastSeekCommandPositionMs: Int64 = -1
    private var spotifyPlaybackInteractionGuard = SpotifyPlaybackInteractionGuard()
    private var automaticUpdateCheckStarted = false
    private let defaults = UserDefaults.standard
    private let keyLastAutoUpdateCheckMs = "last_auto_update_check_ms"
    private let keyInitialSetupDismissed = "initial_setup_dismissed"
    private let keySpotifyValidatedSourceKey = "spotify_validated_source_key"
    private let autoUpdateCheckIntervalMs: Int64 = 24 * 60 * 60 * 1000
    private var lyricsLoadRequestID = UUID()

    init(settings: AppSettings) {
        self.settings = settings
        lyricsResult = LyricsResult.empty(settings.t("status.waiting_current_track"))
        manualLrclibStatus = settings.t("lyrics.lrclib_search.ready")
        updateStatus = settings.t("update.status_idle")
        inputTitle = defaults.string(forKey: "manual_track_title") ?? ""
        inputArtist = defaults.string(forKey: "manual_track_artist") ?? ""
        inputAlbum = defaults.string(forKey: "manual_track_album") ?? ""
        inputDuration = defaults.string(forKey: "manual_track_duration") ?? ""
        inputSpotifyId = defaults.string(forKey: "manual_track_spotify_id") ?? ""
        inputIsrc = defaults.string(forKey: "manual_track_isrc") ?? ""
        spotifyUserConnected = spotifyUserPlaybackService.connected
        spotifyAppRemotePlaybackService.onPlaybackSnapshot = { [weak self] playback in
            guard let self else { return }
            spotifyAppRemoteConnected = true
            spotifyUserConnected = true
            spotifyLivePolling = true
            spotifyDeviceName = playback.deviceName
            applySpotifyPlayback(playback, loadLyricsIfNeeded: true)
            hydrateSpotifyAppRemoteMetadataIfNeeded(playback)
        }
        spotifyAppRemotePlaybackService.onLog = { [weak self] message in
            self?.appendLog(message)
        }
        spotifyAppRemotePlaybackService.onConnectionChanged = { [weak self] connected in
            self?.spotifyAppRemoteConnected = connected
        }
        pictureInPictureController.onSetPlaying = { [weak self] playing in
            self?.setPlayback(playing: playing)
        }
        pictureInPictureController.onSkip = { [weak self] deltaMs in
            self?.skip(by: deltaMs)
        }
        pictureInPictureController.onLog = { [weak self] message in
            self?.appendLog(message)
        }
        pictureInPictureController.onStartFailure = { [weak self] in
            guard let self else { return }
            self.showSavedToast(self.settings.t("pip.enter_failed"))
        }
        startBluetoothRouteMonitoring()
        startClock()
    }

    deinit {
        timer?.invalidate()
        loadTask?.cancel()
        metadataTranslationTask?.cancel()
        furiganaRefreshTask?.cancel()
        manualTask?.cancel()
        tmiTask?.cancel()
        toastTask?.cancel()
        pollinationsAuthTask?.cancel()
        spotifyPollTask?.cancel()
        spotifyMetadataHydrationTask?.cancel()
        updateTask?.cancel()
        if let audioRouteObserver {
            NotificationCenter.default.removeObserver(audioRouteObserver)
        }
    }

    var hasTrackInput: Bool {
        !inputTitle.trimmed.isEmpty && !inputArtist.trimmed.isEmpty
    }

    var pollinationsConnected: Bool {
        !settings.pollinationsAccessToken.trimmed.isEmpty
    }

    var pollinationsAuthStatusText: String {
        if !pollinationsAuthStatus.trimmed.isEmpty {
            return pollinationsAuthStatus
        }
        if pollinationsConnected {
            return settings.tf("pollinations.status_connected_format", maskAccessToken(settings.pollinationsAccessToken))
        }
        return settings.t("pollinations.status_disconnected")
    }

    var pollinationsCanOpenLoginPage: Bool {
        pollinationsAuthInFlight && pollinationsAuthVerificationURL != nil
    }

    var pollinationsCanTestToken: Bool {
        !pollinationsAuthInFlight && !firstPollinationsAuthToken().isEmpty
    }

    var canResolveSpotifyMetadata: Bool {
        !TrackSnapshot.extractSpotifyTrackId(inputSpotifyId).isEmpty
    }

    var initialSetupComplete: Bool {
        settings.snapshot.hasSpotifyClientId
    }

    var titleText: String {
        metadataTranslation?.title.trimmed.isEmpty == false ? metadataTranslation!.title : (currentTrack?.title ?? inputTitle)
    }

    var artistText: String {
        metadataTranslation?.artist.trimmed.isEmpty == false ? metadataTranslation!.artist : (currentTrack?.artist ?? inputArtist)
    }

    var albumText: String {
        currentTrack?.album ?? inputAlbum
    }

    var durationMs: Int64 {
        currentTrack?.durationMs ?? parseDurationMs(inputDuration)
    }

    var hasBluetoothAudioDevice: Bool {
        !bluetoothAudioDeviceKey.isEmpty
    }

    var currentTrackKey: String {
        currentTrack?.stableKey ?? ""
    }

    var adjustedPositionMs: Int64 {
        let adjusted = nowPositionMs + Int64(trackOffsetMs + bluetoothOffsetMs)
        if durationMs > 0 {
            return max(0, min(durationMs, adjusted))
        }
        return max(0, adjusted)
    }

    var firstLyricTimeMs: Int64 {
        let source = baseLyricsResult.lines.isEmpty ? lyricsResult : baseLyricsResult
        return Self.firstLyricTimeMs(in: source)
    }

    var effectiveDetectedLyricsSourceLang: String {
        let lines = baseLyricsResult.lines.isEmpty ? lyricsResult.lines : baseLyricsResult.lines
        return detectedSourceLang(lines: lines)
    }

    var effectiveSelectedRuleSourceLang: String {
        effectiveSelectedSourceLang(lines: baseLyricsResult.lines.isEmpty ? lyricsResult.lines : baseLyricsResult.lines)
    }

    var activeLineIndex: Int {
        activeLineIndex(at: adjustedPositionMs)
    }

    func refreshLocalizedStatusStrings() {
        if status == .idle, currentTrack == nil, lyricsResult.lines.isEmpty {
            lyricsResult = LyricsResult.empty(settings.t("status.waiting_current_track"))
        }
        if manualLrclibStatus.trimmed.isEmpty {
            manualLrclibStatus = settings.t("lyrics.lrclib_search.ready")
        }
        if updateStatus.trimmed.isEmpty {
            updateStatus = settings.t("update.status_idle")
        }
    }

    func setSelectedRuleSourceLang(_ sourceLang: String) {
        let normalized = sourceLang.caseInsensitiveCompare("auto") == .orderedSame
            ? "auto"
            : AppSettings.normalizeSourceLanguageKey(sourceLang)
        guard selectedRuleSourceLang != normalized else { return }
        selectedRuleSourceLang = normalized
        saveLanguageRuleAndRegenerate()
    }

    var youtubePlaybackSeconds: Double {
        guard let youtubeInfo else { return 0 }
        let offsetMs = trackOffsetMs + bluetoothOffsetMs + videoOffsetMs
        var value = Double(max(0, nowPositionMs + Int64(offsetMs))) / 1000.0
        if youtubeInfo.hasCaptionStartTime && !youtubeInfo.isAutoMatchedUnknownCaptionStart {
            value += youtubeInfo.captionStartTimeSeconds - Double(firstLyricTimeMs) / 1000.0
        }
        return max(0, value)
    }

    var youtubePlayerSeconds: Double {
        Double(max(0, nowPositionMs)) / 1000.0
    }

    var youtubeFirstLyricSeconds: Double {
        Double(firstLyricTimeMs) / 1000.0
    }

    var youtubeOffsetSeconds: Double {
        Double(trackOffsetMs + bluetoothOffsetMs + videoOffsetMs) / 1000.0
    }

    func applyManualTrack(loadImmediately: Bool = true) {
        saveManualInputs()
        let duration = parseDurationMs(inputDuration)
        let track = TrackSnapshot(
            title: inputTitle,
            artist: inputArtist,
            album: inputAlbum,
            packageName: "ios.manual",
            mediaId: inputSpotifyId,
            isrc: inputIsrc,
            durationMs: duration,
            positionMs: 0,
            playing: false
        )
        currentTrack = track
        nowPositionMs = 0
        selectedRuleSourceLang = "auto"
        metadataTranslation = nil
        resetYouTubeBackgroundForTrack()
        trackOffsetMs = settings.trackSyncOffsetMs(track.stableKey)
        videoOffsetMs = settings.trackVideoSyncOffsetMs(track.stableKey)
        if loadImmediately {
            reloadLyrics(bypassCache: false)
        }
    }

    func resolveSpotifyMetadata(loadImmediately: Bool = true) {
        let raw = inputSpotifyId
        let trackId = TrackSnapshot.extractSpotifyTrackId(raw)
        guard !trackId.isEmpty else {
            status = .failed(settings.t("status.spotify_track_required"))
            return
        }
        guard requireSpotifyApiCredentials(logMessage: "spotify manual metadata: Spotify API client id/secret is required") else {
            return
        }
        resolvingSpotifyMetadata = true
        status = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let resolved = try await lyricsRepository.resolveSpotifyTrack(raw, settings: settings.snapshot) else {
                    resolvingSpotifyMetadata = false
                    status = .failed(settings.t("status.spotify_metadata_not_found"))
                    appendLog("spotify manual metadata: no track found")
                    return
                }
                appendLogs(resolved.logs)
                guard !resolved.title.isEmpty, !resolved.artist.isEmpty else {
                    resolvingSpotifyMetadata = false
                    status = .setupRequired
                    appendLog("spotify manual metadata: Spotify API credentials unavailable")
                    return
                }
                inputSpotifyId = resolved.spotifyId
                inputTitle = resolved.title
                inputArtist = resolved.artist
                inputAlbum = resolved.album
                inputIsrc = resolved.isrc
                if resolved.durationMs > 0 {
                    inputDuration = formatDurationInput(resolved.durationMs)
                }
                let track = TrackSnapshot(
                    title: resolved.title,
                    artist: resolved.artist,
                    album: resolved.album,
                    packageName: "ios.spotify",
                    mediaId: resolved.spotifyId,
                    isrc: resolved.isrc,
                    durationMs: resolved.durationMs,
                    positionMs: 0,
                    playing: false,
                    artworkURL: resolved.artworkURL
                )
                currentTrack = track
                nowPositionMs = 0
                selectedRuleSourceLang = "auto"
                metadataTranslation = nil
                resetYouTubeBackgroundForTrack()
                trackOffsetMs = settings.trackSyncOffsetMs(track.stableKey)
                videoOffsetMs = settings.trackVideoSyncOffsetMs(track.stableKey)
                saveManualInputs()
                resolvingSpotifyMetadata = false
                if loadImmediately {
                    reloadLyrics(bypassCache: false)
                } else {
                    status = .idle
                }
            } catch {
                resolvingSpotifyMetadata = false
                status = .failed(error.localizedDescription)
                appendLog("spotify manual metadata failed: \(error.localizedDescription)")
            }
        }
    }

    func connectSpotifyUserAndStartPolling() {
        let clientId = settings.spotifyClientId.trimmed
        guard requireSpotifyLiveClientId(logMessage: "spotify live: Spotify Client ID is required") else {
            return
        }
        spotifyPollTask?.cancel()
        spotifyPollTask = nil
        spotifyUserPlaybackService.prepare(clientId: clientId)
        spotifyUserConnected = spotifyUserPlaybackService.connected
        spotifyLivePolling = true
        spotifyAppRemoteConnected = false
        appendLog("spotify live: App Remote connection starting")
        spotifyAppRemotePlaybackService.start(clientId: clientId) { [weak self] in
            Task { @MainActor [weak self] in
                self?.startSpotifyWebApiLive(clientId: clientId)
            }
        }
    }

    func startSpotifyLivePolling() {
        guard spotifyUserPlaybackService.connected else {
            connectSpotifyUserAndStartPolling()
            return
        }
        spotifyPollTask?.cancel()
        spotifyLivePolling = true
        appendLog("spotify live: polling started")
        spotifyPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await refreshSpotifyPlayback(loadLyricsIfNeeded: true)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func resumeSpotifyLiveIfAuthorized() {
#if targetEnvironment(simulator)
        let hasReusableAuthorization = spotifyUserPlaybackService.connected
#else
        let hasReusableAuthorization = spotifyAppRemotePlaybackService.hasStoredAuthorization
            || spotifyUserPlaybackService.connected
#endif
        guard !spotifyLivePolling,
              !settings.spotifyClientId.trimmed.isEmpty,
              hasReusableAuthorization else { return }
        appendLog("spotify live: restoring authorized connection")
        connectSpotifyUserAndStartPolling()
    }

    func appDidBecomeActive() {
        guard spotifyLivePolling,
              !spotifyAppRemotePlaybackService.connected,
              !spotifyAppRemotePlaybackService.connecting,
              !spotifyUserPlaybackService.authorizing,
              spotifyPollTask == nil else { return }
        let clientId = settings.spotifyClientId.trimmed
        guard !clientId.isEmpty else { return }
        appendLog("spotify live: foreground reconnect")
        spotifyAppRemotePlaybackService.start(clientId: clientId) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.spotifyUserPlaybackService.connected {
                    self.startSpotifyLivePolling()
                } else {
                    self.startSpotifyWebApiLive(clientId: clientId)
                }
            }
        }
    }

    func appDidEnterBackground() {
        guard spotifyLivePolling else { return }
        spotifyPollTask?.cancel()
        spotifyPollTask = nil
        spotifyPlaybackRefreshBurstTask?.cancel()
        spotifyPlaybackRefreshBurstTask = nil
        spotifyAppRemotePlaybackService.suspend()
        appendLog("spotify live: background connection suspended")
    }

    func stopSpotifyLivePolling() {
        spotifyPollTask?.cancel()
        spotifyPollTask = nil
        spotifyMetadataHydrationTask?.cancel()
        spotifyMetadataHydrationTask = nil
        spotifyPlaybackRefreshBurstTask?.cancel()
        spotifyPlaybackRefreshBurstTask = nil
        spotifyMetadataHydrationTrackId = ""
        spotifyLivePolling = false
        spotifyAppRemoteConnected = false
        spotifyPlaybackInteractionGuard.reset()
        spotifyAppRemotePlaybackService.stop()
        appendLog("spotify live: polling stopped")
    }

    func disconnectSpotifyUser() {
        stopSpotifyLivePolling()
        spotifyAppRemotePlaybackService.disconnectAndForget()
        spotifyUserPlaybackService.disconnect()
        spotifyUserConnected = false
        spotifyDeviceName = ""
        appendLog("spotify live: disconnected")
    }

    func handleOpenURL(_ url: URL) {
        if spotifyAppRemotePlaybackService.handleOpenURL(url) {
            return
        }
    }

    func refreshSpotifyPlayback(loadLyricsIfNeeded: Bool = true) async {
        if spotifyAppRemotePlaybackService.connected {
            spotifyAppRemotePlaybackService.refreshPlayerState()
            return
        }
        let clientId = settings.spotifyClientId.trimmed
        guard requireSpotifyLiveClientId(logMessage: "spotify live: Spotify Client ID is required") else {
            return
        }
        do {
            guard let playback = try await spotifyUserPlaybackService.currentPlayback(clientId: clientId) else {
                spotifyUserConnected = spotifyUserPlaybackService.connected
                appendLog("spotify live: no currently playing track")
                return
            }
            spotifyUserConnected = true
            spotifyDeviceName = playback.deviceName
            applySpotifyPlayback(playback, loadLyricsIfNeeded: loadLyricsIfNeeded)
        } catch {
            spotifyUserConnected = spotifyUserPlaybackService.connected
            appendLog("spotify live refresh failed: \(error.localizedDescription)")
            if !spotifyUserPlaybackService.connected {
                spotifyLivePolling = false
            }
        }
    }

    func reloadLyrics(bypassCache: Bool) {
        if currentTrack == nil {
            applyManualTrack(loadImmediately: false)
        }
        guard let track = currentTrack, track.hasUsableMetadata else {
            status = .failed(settings.t("status.manual_track_required"))
            return
        }
        cancelLyricsLoadTask()
        status = .loading
        logs = []
        manualCandidates = []
        metadataTranslation = nil
        let loadingResult = LyricsResult.empty(settings.t("status.lyrics_loading"))
        baseLyricsResult = loadingResult
        lyricsResult = loadingResult
        resetYouTubeBackgroundForTrack()
        let requestID = lyricsLoadRequestID
        loadTask = Task { [weak self] in
            await self?.runLyricsPipeline(track: track, bypassCache: bypassCache, requestID: requestID)
        }
    }

    func showTmiForCurrentTrack(bypassCache: Bool = false) {
        let snapshot = currentTrack ?? pendingManualTrackSnapshot()
        guard let snapshot, snapshot.hasUsableMetadata, !snapshot.isSpotifyDjSegment else {
            appendLog("ai tmi skipped: current track missing")
            return
        }
        let trackKey = snapshot.stableKey
        let needsNewDialog = !tmiPresented || currentTmiRequestKey != trackKey
        currentTmiRequestKey = trackKey
        tmiTrack = snapshot
        tmiPresented = true
        tmiLoading = true
        tmiError = ""
        if needsNewDialog || bypassCache {
            tmiInfo = nil
        }

        let snapshotSettings = settings.snapshot
        guard snapshotSettings.hasApiKey else {
            tmiLoading = false
            tmiError = settings.t("tmi.require_key")
            return
        }

        tmiTask?.cancel()
        tmiTask = Task { [weak self] in
            guard let self else { return }
            let response = await aiRepository.loadTmi(track: snapshot, settings: snapshotSettings, bypassCache: bypassCache)
            if Task.isCancelled { return }
            appendLogs(response.logs)
            guard response.trackKey == currentTmiRequestKey else { return }
            tmiLoading = false
            if let info = response.info {
                tmiInfo = info
                tmiError = ""
            } else {
                tmiError = localizedTmiError(response.errorMessage)
            }
        }
    }

    func regenerateTmiForCurrentTrack() {
        showTmiForCurrentTrack(bypassCache: true)
    }

    func adjustTrackOffsetMs(_ deltaMs: Int) {
        setTrackOffsetMs(trackOffsetMs + deltaMs, notify: true)
    }

    func setTrackOffsetMs(_ offsetMs: Int, notify: Bool) {
        let nextOffset = Self.clampSyncOffset(offsetMs)
        trackOffsetMs = nextOffset
        if notify {
            showSavedToast(settings.tf("toast.sync_offset_format", formatSignedMs(nextOffset)))
        }
    }

    func adjustBluetoothOffsetMs(_ deltaMs: Int) {
        setBluetoothOffsetMs(bluetoothOffsetMs + deltaMs, notify: true)
    }

    func setBluetoothOffsetMs(_ offsetMs: Int, notify: Bool) {
        guard !bluetoothAudioDeviceKey.isEmpty else {
            bluetoothOffsetMs = 0
            if notify {
                showSavedToast(settings.t("lyrics.bluetooth_sync.no_device"))
            }
            return
        }
        let nextOffset = Self.clampSyncOffset(offsetMs)
        bluetoothOffsetMs = nextOffset
        if notify {
            showSavedToast(settings.tf("toast.bluetooth_sync_offset_format", bluetoothAudioDeviceName, formatSignedMs(nextOffset)))
        }
    }

    func adjustVideoOffsetMs(_ deltaMs: Int) {
        setVideoOffsetMs(videoOffsetMs + deltaMs, notify: true)
    }

    func setVideoOffsetMs(_ offsetMs: Int, notify: Bool) {
        let nextOffset = Self.clampSyncOffset(offsetMs)
        videoOffsetMs = nextOffset
        if notify {
            showSavedToast(settings.tf("toast.video_sync_offset_format", formatSignedMs(nextOffset)))
        }
    }

    func showSavedToast(_ message: String) {
        let trimmed = message.trimmed
        guard !trimmed.isEmpty else { return }
        toastTask?.cancel()
        toastMessage = trimmed
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = ""
        }
    }

    private func localizedTmiError(_ message: String) -> String {
        let trimmed = message.trimmed
        guard !trimmed.isEmpty else {
            return settings.t("tmi.no_data")
        }
        let lower = trimmed.lowercased()
        if trimmed == "tmi.require_key"
            || (lower.contains("api key") && lower.contains("required")) {
            return settings.t("tmi.require_key")
        }
        return trimmed
    }

    private static func clampSyncOffset(_ offsetMs: Int) -> Int {
        max(-10_000, min(10_000, offsetMs))
    }

    private func formatSignedMs(_ offsetMs: Int) -> String {
        offsetMs > 0 ? "+\(offsetMs)ms" : "\(offsetMs)ms"
    }

    func togglePlayback() {
        guard let track = currentTrack else { return }
        setPlayback(playing: !track.playing)
    }

    private func setPlayback(playing targetPlaying: Bool) {
        guard var track = currentTrack else { return }
        guard track.playing != targetPlaying else { return }
        let position = track.positionNow()
        if spotifyAppRemotePlaybackService.connected || spotifyLivePolling {
            spotifyPlaybackInteractionGuard.registerPlayback(
                trackKey: track.stableKey,
                playing: targetPlaying,
                uptime: ProcessInfo.processInfo.systemUptime
            )
        }
        track = track.withPlayback(positionMs: position, playing: targetPlaying)
        currentTrack = track
        nowPositionMs = track.positionNow()
        if spotifyAppRemotePlaybackService.connected {
            spotifyAppRemotePlaybackService.setPlayback(playing: targetPlaying)
            scheduleSpotifyPlaybackRefreshBurst(loadLyricsIfNeeded: false)
            return
        }
        guard spotifyLivePolling else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let clientId = self.settings.spotifyClientId
            await self.sendSpotifyPlaybackCommand {
                try await self.spotifyUserPlaybackService.setPlayback(playing: targetPlaying, clientId: clientId)
            }
        }
    }

    func startLyricsPictureInPicture() -> Bool {
        updatePictureInPictureState(force: true)
        return pictureInPictureController.start()
    }

    func stopLyricsPictureInPicture() {
        pictureInPictureController.stop()
    }

    func seek(to fraction: Double) {
        guard var track = currentTrack else { return }
        let duration = max(0, track.durationMs)
        let position = Int64((max(0, min(1, fraction)) * Double(duration)).rounded())
        seekPlayer(to: position, track: &track)
    }

    func seek(toPlaybackPositionMs positionMs: Int64) {
        guard var track = currentTrack else { return }
        let upperBound = track.durationMs > 0 ? track.durationMs : Int64.max
        let position = max(0, min(upperBound, positionMs))
        seekPlayer(to: position, track: &track)
    }

    func seek(toLyricsTimeMs lyricsTimeMs: Int64) {
        guard var track = currentTrack else { return }
        let duration = max(0, track.durationMs)
        let target = lyricsTimeMs - Int64(trackOffsetMs + bluetoothOffsetMs)
        let position = duration > 0 ? max(0, min(duration, target)) : max(0, target)
        seekPlayer(to: position, track: &track)
        lyricsFocusRequestRevision &+= 1
    }

    private func seekPlayer(to position: Int64, track: inout TrackSnapshot) {
        track = track.withPlayback(positionMs: position, playing: track.playing)
        currentTrack = track
        nowPositionMs = position
        guard shouldSendSeekCommand(target: position) else { return }
        if spotifyAppRemotePlaybackService.connected || spotifyLivePolling {
            spotifyPlaybackInteractionGuard.registerSeek(
                trackKey: track.stableKey,
                positionMs: position,
                uptime: ProcessInfo.processInfo.systemUptime
            )
        }
        if spotifyAppRemotePlaybackService.connected {
            spotifyAppRemotePlaybackService.seek(positionMs: position)
            scheduleSpotifyPlaybackRefreshBurst(loadLyricsIfNeeded: false)
            return
        }
        guard spotifyLivePolling else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let clientId = self.settings.spotifyClientId
            await self.sendSpotifyPlaybackCommand {
                try await self.spotifyUserPlaybackService.seek(positionMs: position, clientId: clientId)
            }
        }
    }

    func skip(by deltaMs: Int64) {
        guard var track = currentTrack else { return }
        let target = max(0, min(track.durationMs > 0 ? track.durationMs : Int64.max, track.positionNow() + deltaMs))
        track = track.withPlayback(positionMs: target, playing: track.playing)
        currentTrack = track
        nowPositionMs = target
        guard shouldSendSeekCommand(target: target) else { return }
        if spotifyAppRemotePlaybackService.connected || spotifyLivePolling {
            spotifyPlaybackInteractionGuard.registerSeek(
                trackKey: track.stableKey,
                positionMs: target,
                uptime: ProcessInfo.processInfo.systemUptime
            )
        }
        if spotifyAppRemotePlaybackService.connected {
            spotifyAppRemotePlaybackService.seek(positionMs: target)
            scheduleSpotifyPlaybackRefreshBurst(loadLyricsIfNeeded: false)
            return
        }
        guard spotifyLivePolling else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let clientId = self.settings.spotifyClientId
            await self.sendSpotifyPlaybackCommand {
                try await self.spotifyUserPlaybackService.seek(positionMs: target, clientId: clientId)
            }
        }
    }

    func skipToNextTrack() {
        if spotifyAppRemotePlaybackService.connected {
            spotifyAppRemotePlaybackService.skipToNext()
            scheduleSpotifyPlaybackRefreshBurst(loadLyricsIfNeeded: true)
            return
        }
        guard spotifyLivePolling else {
            appendLog("spotify live: next track requires live polling")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let clientId = self.settings.spotifyClientId
            await self.sendSpotifyPlaybackCommand(loadLyricsIfNeeded: true) {
                try await self.spotifyUserPlaybackService.skipToNext(clientId: clientId)
            }
        }
    }

    func skipToPreviousTrack() {
        if spotifyAppRemotePlaybackService.connected {
            spotifyAppRemotePlaybackService.skipToPrevious()
            scheduleSpotifyPlaybackRefreshBurst(loadLyricsIfNeeded: true)
            return
        }
        guard spotifyLivePolling else {
            appendLog("spotify live: previous track requires live polling")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let clientId = self.settings.spotifyClientId
            await self.sendSpotifyPlaybackCommand(loadLyricsIfNeeded: true) {
                try await self.spotifyUserPlaybackService.skipToPrevious(clientId: clientId)
            }
        }
    }

    private func shouldSendSeekCommand(target: Int64) -> Bool {
        let now = monotonicUptimeMs()
        if now - lastSeekCommandUptimeMs < 220, abs(target - lastSeekCommandPositionMs) < 700 {
            return false
        }
        lastSeekCommandUptimeMs = now
        lastSeekCommandPositionMs = target
        return true
    }

    private func monotonicUptimeMs() -> Int64 {
        Int64((ProcessInfo.processInfo.systemUptime * 1000).rounded())
    }

    func searchManualCandidates() {
        manualTask?.cancel()
        let title = inputTitle.trimmed
        guard !title.isEmpty else {
            manualCandidates = []
            searchingManualCandidates = false
            manualLrclibStatus = settings.t("lyrics.lrclib_search.empty_title")
            return
        }
        searchingManualCandidates = true
        manualCandidates = []
        manualLrclibStatus = settings.t("lyrics.lrclib_search.loading")
        let track = currentTrack
        let artist = inputArtist.trimmed
        manualTask = Task { [weak self] in
            guard let self else { return }
            do {
                let candidates = try await lyricsRepository.searchManualLrclib(track: track, title: title, artist: artist)
                if Task.isCancelled { return }
                manualCandidates = candidates
                manualLrclibStatus = candidates.isEmpty
                    ? settings.t("lyrics.lrclib_search.no_results")
                    : settings.tf("lyrics.lrclib_search.result_count_format", candidates.count)
                appendLog("manual LRCLIB search: candidates=\(candidates.count)")
            } catch {
                let detail = error.localizedDescription.trimmed.isEmpty ? "unknown error" : error.localizedDescription.trimmed
                manualCandidates = []
                manualLrclibStatus = settings.tf("lyrics.lrclib_search.error_format", detail)
                showSavedToast(manualLrclibStatus)
                appendLog("manual LRCLIB search failed: \(detail)")
            }
            searchingManualCandidates = false
        }
    }

    func applyManualCandidate(_ candidate: ManualLrclibCandidate) {
        guard let track = currentTrack else { return }
        cancelLyricsLoadTask()
        status = .loading
        manualLrclibStatus = settings.t("lyrics.lrclib_search.selecting")
        let loadingResult = LyricsResult.empty(settings.t("status.lyrics_loading"))
        baseLyricsResult = loadingResult
        lyricsResult = loadingResult
        let requestID = lyricsLoadRequestID
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await lyricsRepository.loadManualLrclibCandidate(track: track, selected: candidate, settings: settings.snapshot)
                guard isLyricsLoadCurrent(requestID, trackKey: track.stableKey) else { return }
                let base = localizedLyricsResult(result)
                baseLyricsResult = base
                lyricsResult = base
                resetCurrentFurigana()
                requestMetadataTranslation(track: track, base: base, bypassCache: false)
                let final = await applyLyricsSupplements(track: track, base: base, bypassCache: false)
                guard isLyricsLoadCurrent(requestID, trackKey: track.stableKey) else { return }
                lyricsResult = final
                status = .loaded
                manualLrclibStatus = settings.t("lyrics.lrclib_search.loaded")
                showSavedToast(manualLrclibStatus)
                appendLog("manual LRCLIB applied: id=\(candidate.id)")
                await loadYouTubeIfNeeded(track: track, result: final)
            } catch {
                guard isLyricsLoadCurrent(requestID, trackKey: track.stableKey) else { return }
                let detail = error.localizedDescription.trimmed.isEmpty ? "unknown error" : error.localizedDescription.trimmed
                manualLrclibStatus = settings.tf("lyrics.lrclib_search.error_format", detail)
                status = .failed(detail)
                showSavedToast(manualLrclibStatus)
                appendLog("manual LRCLIB apply failed: \(detail)")
            }
        }
    }

    private func localizedLyricsResult(_ result: LyricsResult) -> LyricsResult {
        guard result.lines.isEmpty else { return result }
        let key: String
        switch result.detail {
        case "가사를 찾지 못했습니다":
            key = "repo.lyrics_not_found"
        case "연주곡입니다":
            key = "repo.instrumental"
        case "표시할 수 있는 가사가 없습니다":
            key = "repo.no_renderable_lyrics"
        default:
            return result
        }
        return LyricsResult(
            lines: result.lines,
            providerLabel: result.providerLabel,
            detail: settings.t(key),
            karaoke: result.karaoke,
            isrc: result.isrc,
            spotifyTrackId: result.spotifyTrackId,
            contributors: result.contributors
        )
    }

    func clearCachesForCurrentTrack() {
        guard let track = currentTrack else {
            showSavedToast(settings.t("toast.current_track_missing"))
            return
        }
        furiganaRepository.clearTrackCache(track.stableKey)
        let cacheIsrc = IvLyricsUtilities.firstNonEmpty(baseLyricsResult.isrc, lyricsResult.isrc, track.isrc)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.lyricsRepository.clearCacheForTrack(track.stableKey)
            await self.lyricsRepository.clearSyncDataCacheForIsrc(cacheIsrc)
            await self.aiRepository.clearTrackCache(track.stableKey)
            await self.youtubeRepository.clearCacheForIsrc(cacheIsrc)
            self.appendLog("track caches cleared")
            self.showSavedToast(self.settings.t("toast.current_cache_cleared"))
            self.reloadLyrics(bypassCache: true)
        }
    }

    func clearAllCaches() {
        furiganaRepository.clearCache()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.lyricsRepository.clearCache()
            await self.aiRepository.clearCache()
            await self.youtubeRepository.clearCache()
            self.appendLog("all caches cleared")
            self.showSavedToast(self.settings.t("toast.all_cache_cleared"))
            self.reloadLyrics(bypassCache: true)
        }
    }

    func clearAiCaches() {
        furiganaRepository.clearCache()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.aiRepository.clearCache()
            self.appendLog(self.settings.t("status.ai_cache_cleared"))
            self.showSavedToast(self.settings.t("toast.ai_cache_cleared"))
        }
    }

    func saveAiSettingsAndRegenerate() {
        showSavedToast(settings.t("toast.settings_saved"))
        regenerateCurrentAiSupplements(statusKey: "toast.settings_saved")
    }

    func saveLanguageRuleAndRegenerate() {
        showSavedToast(settings.t("toast.language_rule_saved"))
        regenerateCurrentAiSupplements(statusKey: "toast.language_rule_saved")
    }

    func outputLanguageChanged() {
        showSavedToast(settings.t("toast.pronunciation_language_saved"))
        regenerateCurrentAiSupplements(statusKey: "toast.pronunciation_language_saved")
    }

    func uiLanguageChanged() {
        refreshLocalizedStatusStrings()
        showSavedToast(settings.t("toast.ui_language_saved"))
        guard settings.outputLang.caseInsensitiveCompare(AppSettings.outputLangSameUI) == .orderedSame else {
            return
        }
        regenerateCurrentAiSupplements(statusKey: "toast.ui_language_saved")
    }

    func metadataTranslationSettingChanged(enabled: Bool) {
        metadataTranslationTask?.cancel()
        metadataTranslationTask = nil
        metadataTranslation = nil
        guard enabled,
              let track = currentTrack,
              !baseLyricsResult.lines.isEmpty else {
            return
        }
        requestMetadataTranslation(track: track, base: baseLyricsResult, bypassCache: true)
    }

    func japaneseFuriganaSettingChanged(enabled: Bool) {
        furiganaRefreshTask?.cancel()
        furiganaRefreshTask = nil
        guard enabled else {
            setLyricsSupplementLoading(
                pronunciation: lyricsSupplementPronunciationLoading,
                translation: lyricsSupplementTranslationLoading,
                furigana: false
            )
            return
        }
        guard let track = currentTrack,
              !baseLyricsResult.lines.isEmpty else {
            appendLog(settings.t("status.no_lyrics_to_apply"))
            return
        }
        let trackKey = track.stableKey
        let base = baseLyricsResult
        furiganaRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.loadFuriganaIfNeeded(track: track, base: base, bypassCache: false)
            guard !Task.isCancelled,
                  self.settings.japaneseFuriganaEnabled,
                  self.currentTrack?.stableKey == trackKey else {
                return
            }
            self.appendLog("furigana setting applied to current track")
        }
    }

    func maybeShowInitialSetup() {
        guard !initialSetupComplete, !defaults.bool(forKey: keyInitialSetupDismissed) else { return }
        showInitialSetup()
    }

    func showInitialSetup() {
        onboardingStep = initialSetupComplete ? 1 : 0
        initialSetupPresented = true
    }

    @discardableResult
    private func requireSpotifyLiveClientId(logMessage: String) -> Bool {
        guard settings.snapshot.hasSpotifyClientId else {
            spotifyValidationStatus = settings.t("toast.spotify_client_id_missing")
            status = .setupRequired
            showSavedToast(spotifyValidationStatus)
            appendLog(logMessage)
            if !initialSetupPresented {
                showInitialSetup()
            }
            return false
        }
        return true
    }

    @discardableResult
    private func requireSpotifyApiCredentials(logMessage: String) -> Bool {
        guard settings.snapshot.hasSpotifyCredentials else {
            spotifyValidationStatus = settings.t("toast.spotify_missing")
            status = .setupRequired
            showSavedToast(settings.t("toast.spotify_missing"))
            appendLog(logMessage)
            if !initialSetupPresented {
                showInitialSetup()
            }
            return false
        }
        return true
    }

    func advanceOnboarding() {
        onboardingStep = min(2, onboardingStep + 1)
    }

    func retreatOnboarding() {
        onboardingStep = max(0, onboardingStep - 1)
    }

    func dismissInitialSetup(remindLater: Bool = true) {
        if !remindLater {
            defaults.set(true, forKey: keyInitialSetupDismissed)
        }
        initialSetupPresented = false
    }

    func finishInitialSetup() {
        guard settings.snapshot.hasSpotifyClientId else {
            status = .setupRequired
            appendLog("initial setup: Spotify Client ID is required")
            return
        }
        if settings.spotifyClientSecret.trimmed.isEmpty {
            spotifyValidationStatus = settings.t("spotify.status_app_remote_ready")
            defaults.set(true, forKey: keyInitialSetupDismissed)
            initialSetupPresented = false
            showSavedToast(settings.t("toast.spotify_saved"))
            appendLog("initial setup: App Remote configured with Client ID; API metadata enrichment disabled")
            connectSpotifyUserAndStartPolling()
            return
        }
        validateSpotifyApiCredentials(reloadOnChange: true, startLiveAfterSuccess: true)
    }

    func validateSpotifyApiCredentials(reloadOnChange: Bool = true, startLiveAfterSuccess: Bool = false) {
        guard !spotifyCredentialsValidationInFlight else {
            appendLog("spotify api validation: already in flight")
            return
        }
        let clientId = settings.spotifyClientId.trimmed
        let clientSecret = settings.spotifyClientSecret.trimmed
        guard !clientId.isEmpty else {
            spotifyValidationStatus = settings.t("toast.spotify_client_id_missing")
            status = .setupRequired
            showSavedToast(spotifyValidationStatus)
            appendLog("spotify api validation: missing client id")
            return
        }
        guard !clientSecret.isEmpty else {
            spotifyValidationStatus = settings.t("spotify.status_app_remote_ready")
            showSavedToast(settings.t("toast.spotify_saved"))
            appendLog("spotify api validation: Client ID saved for App Remote; Client Secret not configured")
            if startLiveAfterSuccess {
                defaults.set(true, forKey: keyInitialSetupDismissed)
                initialSetupPresented = false
                connectSpotifyUserAndStartPolling()
            }
            return
        }
        spotifyCredentialsValidationInFlight = true
        spotifyValidationStatus = settings.t("spotify.status_checking")
        showSavedToast(settings.t("toast.spotify_checking"))
        Task { [weak self] in
            guard let self else { return }
            do {
                let validation = try await lyricsRepository.validateSpotifyCredentials(clientId: clientId, clientSecret: clientSecret)
                appendLogs(validation.logs)
                let sourceKey = spotifyCredentialsSourceKey(clientId: clientId, clientSecret: clientSecret)
                let changed = defaults.string(forKey: keySpotifyValidatedSourceKey) != sourceKey
                defaults.set(sourceKey, forKey: keySpotifyValidatedSourceKey)
                spotifyCredentialsValidationInFlight = false
                spotifyValidationStatus = settings.t("spotify.status_configured")
                showSavedToast(settings.t("toast.spotify_saved"))
                appendLog("spotify api validation: token verified, ttl=\(validation.expiresInSeconds)s")
                if changed {
                    await lyricsRepository.clearCache()
                    spotifyHydratedTrackIds.removeAll()
                    appendLog("spotify api settings changed: token verified, credentials saved, lyrics cache cleared")
                }
                if changed && reloadOnChange && currentTrack?.hasUsableMetadata == true {
                    reloadLyrics(bypassCache: true)
                }
                if startLiveAfterSuccess {
                    defaults.set(true, forKey: keyInitialSetupDismissed)
                    initialSetupPresented = false
                    connectSpotifyUserAndStartPolling()
                }
            } catch {
                spotifyCredentialsValidationInFlight = false
                let detail = error.localizedDescription.trimmed.isEmpty ? "unknown error" : error.localizedDescription.trimmed
                spotifyValidationStatus = settings.tf("spotify.status_invalid_format", detail)
                showSavedToast(settings.t("toast.spotify_invalid"))
                appendLog("spotify api validation failed: \(detail)")
            }
        }
    }

    func maybeStartAutomaticUpdateCheck() {
        guard !automaticUpdateCheckStarted else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let last = Int64(defaults.double(forKey: keyLastAutoUpdateCheckMs))
        guard now - last >= autoUpdateCheckIntervalMs else { return }
        automaticUpdateCheckStarted = true
        defaults.set(Double(now), forKey: keyLastAutoUpdateCheckMs)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            self?.checkForUpdates(manual: false)
        }
    }

    func checkForUpdates(manual: Bool) {
        if updateCheckInFlight {
            if manual {
                appendLog("update check: already in flight")
            }
            return
        }
        updateTask?.cancel()
        updateCheckInFlight = true
        updateStatus = settings.t("update.status_checking")
        if manual {
            showSavedToast(settings.t("toast.update_checking"))
            appendLog("update check: started")
        }
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await updateChecker.checkLatest()
                if Task.isCancelled { return }
                updateCheckInFlight = false
                pendingUpdateInfo = info
                if info.updateAvailable {
                    let version = info.latestDisplayVersion
                    updateStatus = settings.tf("update.status_available_format", version)
                    updateDialogPresented = true
                    if manual {
                        showSavedToast(settings.tf("toast.update_available_format", version))
                    }
                    appendLog("update available: current=\(info.currentVersionName) latest=\(version)")
                } else {
                    updateStatus = settings.tf("update.status_latest_format", info.currentVersionName)
                    if manual {
                        showSavedToast(settings.t("toast.update_latest"))
                        appendLog("update check: latest version")
                    }
                }
            } catch {
                if Task.isCancelled { return }
                updateCheckInFlight = false
                let detail = error.localizedDescription.trimmed.isEmpty ? "unknown error" : error.localizedDescription.trimmed
                updateStatus = settings.tf("update.status_failed_format", detail)
                if manual {
                    showSavedToast(settings.t("toast.update_failed"))
                }
                appendLog("update check failed: \(detail)")
            }
        }
    }

    func openUpdateReleasePage(_ info: AppUpdateInfo? = nil) {
        let urlString = IvLyricsUtilities.firstNonEmpty(
            info?.releaseURL,
            pendingUpdateInfo?.releaseURL,
            "https://github.com/ivLis-Studio/ivLyrics-IOS/releases"
        )
        guard let url = URL(string: urlString) else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        inAppBrowserURL = url
        #endif
    }

    func syncContributorProfileURL(_ contributor: LyricsResult.SyncContributor) async -> URL? {
        let userHash = contributor.userHash.trimmed
        guard contributor.profileAvailable, !userHash.isEmpty else { return nil }
        if let cached = creatorProfileUrlCache[userHash] {
            return cached
        }
        let fallback = syncContributorProfileURL(identifier: userHash)
        do {
            let resolved = try await fetchSyncContributorProfileURL(userHash: userHash, fallback: fallback)
            creatorProfileUrlCache[userHash] = resolved
            return resolved
        } catch {
            appendLog("sync creator profile lookup failed: \(error.localizedDescription)")
            creatorProfileUrlCache[userHash] = fallback
            return fallback
        }
    }

    func openSyncContributorProfile(_ contributor: LyricsResult.SyncContributor) async {
        guard let url = await syncContributorProfileURL(contributor) else { return }
        inAppBrowserURL = url
    }

    func openSpotifyForCurrentTrack() {
        let trackId = TrackSnapshot.extractSpotifyTrackId(
            IvLyricsUtilities.firstNonEmpty(currentTrack?.trackId, lyricsResult.spotifyTrackId, inputSpotifyId)
        )
        let appURLString = trackId.isEmpty ? "spotify://" : "spotify:track:\(trackId)"
        let webURLString = trackId.isEmpty ? "https://open.spotify.com" : "https://open.spotify.com/track/\(trackId)"
        guard let appURL = URL(string: appURLString), let webURL = URL(string: webURLString) else {
            showSavedToast(settings.t("toast.spotify_open_failed"))
            return
        }
        if trackId.isEmpty {
            appendLog("spotify open: no Spotify track id, opening Spotify app")
        }
#if os(iOS)
        let failureMessage = settings.t("toast.spotify_open_failed")
        UIApplication.shared.open(appURL, options: [:]) { [weak self] opened in
            if opened {
                return
            }
            UIApplication.shared.open(webURL, options: [:]) { webOpened in
                guard !webOpened else { return }
                Task { @MainActor in
                    self?.showSavedToast(failureMessage)
                }
            }
        }
#else
        inAppBrowserURL = webURL
#endif
    }

    func openInAppBrowser(_ url: URL) {
        inAppBrowserURL = url
    }

    func closeInAppBrowser() {
        inAppBrowserURL = nil
    }

    func startPollinationsLogin() {
        guard !pollinationsAuthInFlight else { return }
        pollinationsAuthTask?.cancel()
        pollinationsAuthInFlight = true
        pollinationsAuthVerificationURL = nil
        pollinationsAuthUserCode = ""
        pollinationsAuthStatus = settings.t("pollinations.status_requesting")
        pollinationsAuthTask = Task { [weak self] in
            guard let self else { return }
            do {
                let device = try await pollinationsAuthClient.requestDeviceCode()
                pollinationsAuthVerificationURL = device.verificationURL
                pollinationsAuthUserCode = device.userCode
                pollinationsAuthStatus = settings.tf("pollinations.status_code_format", device.userCode)
                openPollinationsLoginPage()

                var intervalMs = device.intervalMs
                while pollinationsAuthInFlight && Date() < device.expiresAt {
                    try await Task.sleep(nanoseconds: UInt64(max(Int64(1), intervalMs)) * 1_000_000)
                    if Task.isCancelled { return }
                    let result = try await pollinationsAuthClient.pollDeviceToken(deviceCode: device.deviceCode)
                    if result.pending {
                        if result.slowDown {
                            intervalMs += 2_000
                        }
                        continue
                    }
                    finishPollinationsLogin(result.accessToken)
                    return
                }
                throw NSError(domain: "ivLyrics.Pollinations", code: -3, userInfo: [NSLocalizedDescriptionKey: "Pollinations login timed out."])
            } catch {
                if Task.isCancelled { return }
                failPollinationsLogin(error)
            }
        }
    }

    func openPollinationsLoginPage() {
        let url = pollinationsAuthVerificationURL ?? URL(string: PollinationsAuthClient.authBaseURL)
        guard let url else { return }
#if os(iOS)
        UIApplication.shared.open(url)
#else
        inAppBrowserURL = url
#endif
    }

    func disconnectPollinationsLogin() {
        pollinationsAuthTask?.cancel()
        pollinationsAuthTask = nil
        pollinationsAuthInFlight = false
        pollinationsAuthVerificationURL = nil
        pollinationsAuthUserCode = ""
        settings.pollinationsAccessToken = ""
        pollinationsAuthStatus = settings.t("pollinations.status_disconnected")
        appendLog("pollinations auth: disconnected")
        showSavedToast(settings.t("pollinations.toast_disconnected"))
    }

    func testPollinationsToken() {
        let token = firstPollinationsAuthToken()
        guard !token.isEmpty else {
            pollinationsAuthStatus = settings.t("pollinations.status_no_token")
            return
        }
        pollinationsAuthStatus = settings.t("pollinations.status_testing")
        Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await pollinationsAuthClient.fetchKeyInfo(accessToken: token)
                let type = info.type.trimmed.isEmpty ? "API" : info.type.trimmed
                let expires = info.expiresInSeconds > 0
                    ? " · " + settings.tf("pollinations.expires_days_format", Int(max(Int64(1), (info.expiresInSeconds + 86_399) / 86_400)))
                    : ""
                pollinationsAuthStatus = (info.valid ? settings.t("pollinations.status_valid") : settings.t("pollinations.status_invalid")) + " · " + type + expires
                appendLog(info.valid ? "pollinations auth: token verified" : "pollinations auth: token invalid")
                showSavedToast(info.valid ? settings.t("pollinations.toast_valid") : settings.t("pollinations.toast_failed"))
            } catch {
                let detail = error.localizedDescription.trimmed.isEmpty ? "unknown error" : error.localizedDescription.trimmed
                pollinationsAuthStatus = settings.tf("pollinations.status_failed_format", detail)
                appendLog("pollinations auth failed: \(detail)")
                showSavedToast(settings.t("pollinations.toast_failed"))
            }
        }
    }

    func refreshBackgroundForCurrentTrack() {
        guard let track = currentTrack else {
            resetYouTubeBackgroundForTrack()
            return
        }
        resetYouTubeBackgroundForTrack()
        Task {
            await loadYouTubeIfNeeded(track: track, result: lyricsResult)
        }
    }

    func progress(for line: LyricsLine) -> Double {
        let position = adjustedPositionMs
        if !line.syllables.isEmpty {
            let start = line.syllables.first?.startTimeMs ?? line.startTimeMs
            let end = line.syllables.last?.endTimeMs ?? line.endTimeMs
            guard end > start else { return position >= start ? 1 : 0 }
            return max(0, min(1, Double(position - start) / Double(end - start)))
        }
        guard line.endTimeMs > line.startTimeMs else {
            return position >= line.startTimeMs ? 1 : 0
        }
        return max(0, min(1, Double(position - line.startTimeMs) / Double(line.endTimeMs - line.startTimeMs)))
    }

    func displayText(for line: LyricsLine) -> String {
        if !line.text.trimmed.isEmpty {
            return line.text
        }
        return line.vocalParts.map { part in
            part.text.trimmed.isEmpty ? part.syllables.map(\.text).joined() : part.text
        }
        .filter { !$0.trimmed.isEmpty }
        .joined(separator: " / ")
    }

    private func pendingManualTrackSnapshot() -> TrackSnapshot? {
        guard hasTrackInput else { return nil }
        return TrackSnapshot(
            title: inputTitle,
            artist: inputArtist,
            album: inputAlbum,
            packageName: "ios.manual",
            mediaId: inputSpotifyId,
            isrc: inputIsrc,
            durationMs: parseDurationMs(inputDuration),
            positionMs: nowPositionMs,
            playing: currentTrack?.playing ?? false,
            artworkURL: currentTrack?.artworkURL
        )
    }

    private func runLyricsPipeline(track: TrackSnapshot, bypassCache: Bool, requestID: UUID) async {
        do {
            appendLog("ios input: manual TrackSnapshot -> Android-compatible lyrics pipeline")
            let loaded = try await lyricsRepository.loadLyrics(
                track: track,
                settings: settings.snapshot
            ) { [weak self] metadata in
                await MainActor.run {
                    self?.applyEarlySpotifyLyricsMetadata(metadata)
                }
            }
            guard isLyricsLoadCurrent(requestID, trackKey: track.stableKey) else { return }
            appendLogs(loaded.logs)
            guard let latestTrack = currentTrack, latestTrack.stableKey == track.stableKey else { return }
            var resolvedTrack = latestTrack
            if !loaded.resolvedIsrc.isEmpty || !loaded.resolvedSpotifyTrackId.isEmpty || loaded.artworkURL != nil {
                resolvedTrack = TrackSnapshot(
                    title: latestTrack.title,
                    artist: latestTrack.artist,
                    album: latestTrack.album,
                    packageName: latestTrack.packageName,
                    mediaId: IvLyricsUtilities.firstNonEmpty(loaded.resolvedSpotifyTrackId, track.mediaId),
                    isrc: IvLyricsUtilities.firstNonEmpty(loaded.resolvedIsrc, track.isrc),
                    durationMs: latestTrack.durationMs > 0 ? latestTrack.durationMs : track.durationMs,
                    positionMs: latestTrack.positionNow(),
                    playbackSpeed: latestTrack.playbackSpeed,
                    playing: latestTrack.playing,
                    artworkURL: loaded.artworkURL ?? latestTrack.artworkURL
                )
            }
            currentTrack = resolvedTrack
            let baseResult = localizedLyricsResult(loaded.result)
            baseLyricsResult = baseResult
            lyricsResult = baseResult
            resetCurrentFurigana()
            trackOffsetMs = settings.trackSyncOffsetMs(loaded.trackKey)
            videoOffsetMs = settings.trackVideoSyncOffsetMs(loaded.trackKey)
            requestMetadataTranslation(track: resolvedTrack, base: baseResult, bypassCache: bypassCache)
            let finalResult = await applyLyricsSupplements(track: resolvedTrack, base: baseResult, bypassCache: bypassCache)
            guard isLyricsLoadCurrent(requestID, trackKey: resolvedTrack.stableKey) else { return }
            lyricsResult = finalResult
            status = .loaded
            await loadYouTubeIfNeeded(track: resolvedTrack, result: finalResult)
        } catch {
            guard isLyricsLoadCurrent(requestID, trackKey: track.stableKey), let failedTrack = currentTrack else { return }
            requestMetadataTranslation(
                track: failedTrack,
                base: LyricsResult.empty(error.localizedDescription),
                bypassCache: false
            )
            lyricsResult = .empty(error.localizedDescription)
            status = .failed(error.localizedDescription)
            appendLog("lyrics pipeline failed: \(error.localizedDescription)")
        }
    }

    private func hydrateSpotifyAppRemoteMetadataIfNeeded(_ playback: SpotifyPlaybackSnapshot) {
        let track = playback.track
        let trackId = track.trackId
        guard !trackId.isEmpty,
              settings.snapshot.hasSpotifyCredentials,
              !spotifyHydratedTrackIds.contains(trackId),
              spotifyMetadataHydrationTrackId != trackId else {
            return
        }
        spotifyMetadataHydrationTask?.cancel()
        spotifyMetadataHydrationTrackId = trackId
        let settingsSnapshot = settings.snapshot
        spotifyMetadataHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let hydration = await lyricsRepository.hydrateSpotifyTrackMetadata(track: track, settings: settingsSnapshot)
            if Task.isCancelled { return }
            spotifyMetadataHydrationTrackId = ""
            spotifyHydratedTrackIds.insert(trackId)
            appendLogs(hydration.logs)
            guard currentTrack?.trackId == trackId else { return }
            let hydratedTrack = hydration.track
            guard hydratedTrack != track else { return }
            let progress = hydratedTrack.positionNow()
            applySpotifyPlayback(
                SpotifyPlaybackSnapshot(
                    track: hydratedTrack.withPlayback(positionMs: progress, playing: playback.playing),
                    progressMs: progress,
                    playing: playback.playing,
                    fetchedAt: Date(),
                    deviceName: playback.deviceName
                ),
                loadLyricsIfNeeded: false
            )
        }
    }

    private func applySpotifyPlayback(_ playback: SpotifyPlaybackSnapshot, loadLyricsIfNeeded: Bool) {
        let playback = spotifyPlaybackInteractionGuard.reconcile(
            playback,
            currentTrack: currentTrack,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        let incoming = playback.track
        let previousKey = currentTrack?.stableKey ?? ""
        let changedTrack = previousKey != incoming.stableKey
        inputTitle = incoming.title
        inputArtist = incoming.artist
        inputAlbum = incoming.album
        inputSpotifyId = incoming.trackId
        inputIsrc = incoming.isrc
        inputDuration = formatDurationInput(incoming.durationMs)
        currentTrack = incoming
        nowPositionMs = playback.progressMs
        trackOffsetMs = settings.trackSyncOffsetMs(incoming.stableKey)
        videoOffsetMs = settings.trackVideoSyncOffsetMs(incoming.stableKey)
        saveManualInputs()
        if changedTrack {
            selectedRuleSourceLang = "auto"
            metadataTranslation = nil
            resetYouTubeBackgroundForTrack()
            appendLog("spotify live track: \(incoming.title) / \(incoming.artist)" + (playback.deviceName.isEmpty ? "" : " / \(playback.deviceName)"))
            cancelLyricsLoadTask()
            let loadingResult = LyricsResult.empty(settings.t(loadLyricsIfNeeded ? "status.lyrics_loading" : "status.lyrics_waiting"))
            baseLyricsResult = loadingResult
            lyricsResult = loadingResult
            status = loadLyricsIfNeeded ? .loading : .idle
            logs = Array(logs.suffix(40))
            guard loadLyricsIfNeeded else { return }
            let requestID = lyricsLoadRequestID
            loadTask = Task { [weak self] in
                await self?.runLyricsPipeline(track: incoming, bypassCache: false, requestID: requestID)
            }
        }
    }

    private func regenerateCurrentAiSupplements(statusKey: String) {
        appendLog(settings.t(statusKey))
        guard let track = currentTrack, !baseLyricsResult.lines.isEmpty else {
            appendLog(settings.t("status.no_lyrics_to_apply"))
            return
        }
        cancelLyricsLoadTask()
        metadataTranslation = nil
        status = .loading
        let base = baseLyricsResult
        let snapshot = settings.snapshot
        let requestID = lyricsLoadRequestID
        loadTask = Task { [weak self] in
            guard let self else { return }
            guard isLyricsLoadCurrent(requestID, trackKey: track.stableKey) else { return }
            self.lyricsResult = base
            self.resetCurrentFurigana()
            self.requestMetadataTranslation(track: track, base: base, bypassCache: true)
            let finalResult = await self.applyLyricsSupplements(track: track, base: base, bypassCache: true)
            guard self.isLyricsLoadCurrent(requestID, trackKey: track.stableKey) else { return }
            self.lyricsResult = finalResult
            self.status = .loaded
            self.appendLog(self.settings.t(snapshot.enabled ? "status.ai_applied" : "status.ai_disabled"))
        }
    }

    private func startSpotifyWebApiLive(clientId: String) {
        guard !spotifyUserPlaybackService.authorizing else {
            appendLog("spotify live: OAuth authorization already in progress")
            return
        }
        appendLog("spotify live: falling back to Web API polling")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if !spotifyUserPlaybackService.connected {
                    appendLog("spotify live: OAuth authorization starting")
                    try await spotifyUserPlaybackService.authorize(clientId: clientId)
                    appendLog("spotify live: OAuth authorization complete")
                }
                spotifyUserConnected = spotifyUserPlaybackService.connected
                startSpotifyLivePolling()
            } catch {
                spotifyUserConnected = spotifyUserPlaybackService.connected
                spotifyLivePolling = false
                spotifyAppRemoteConnected = false
                status = .failed(error.localizedDescription)
                appendLog("spotify live auth failed: \(error.localizedDescription)")
            }
        }
    }

    private func sendSpotifyPlaybackCommand(
        loadLyricsIfNeeded: Bool = false,
        _ operation: @escaping () async throws -> Void
    ) async {
        do {
            try await operation()
            scheduleSpotifyPlaybackRefreshBurst(loadLyricsIfNeeded: loadLyricsIfNeeded)
        } catch {
            appendLog("spotify live command failed: \(error.localizedDescription)")
        }
    }

    private func scheduleSpotifyPlaybackRefreshBurst(loadLyricsIfNeeded: Bool) {
        guard spotifyAppRemotePlaybackService.connected || spotifyLivePolling else { return }
        spotifyPlaybackRefreshBurstTask?.cancel()
        spotifyPlaybackRefreshBurstTask = Task { @MainActor [weak self] in
            for delay in Self.spotifyPlaybackRefreshBurstDelays {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled, let self else { return }
                await self.refreshSpotifyPlayback(loadLyricsIfNeeded: loadLyricsIfNeeded)
            }
        }
    }

    private func applyLyricsSupplements(track: TrackSnapshot, base: LyricsResult, bypassCache: Bool) async -> LyricsResult {
        async let aiResult = applySupplements(track: track, base: base, bypassCache: bypassCache)
        async let furiganaResult = loadFuriganaIfNeeded(track: track, base: base, bypassCache: bypassCache)
        let (supplemented, furigana) = await (aiResult, furiganaResult)
        return mergeFuriganaIntoResult(supplemented, furiganaSource: furigana)
    }

    private func applySupplements(track: TrackSnapshot, base: LyricsResult, bypassCache: Bool) async -> LyricsResult {
        let snapshot = settings.snapshot
        let sourceLang = effectiveSelectedSourceLang(lines: base.lines)
        var result = base
        setLyricsSupplementLoading(pronunciation: false, translation: false, furigana: lyricsSupplementFuriganaLoading)
        let loading = aiSupplementLoadingState(track: track, base: base, snapshot: snapshot, sourceLang: sourceLang)
        guard loading.pronunciation || loading.translation else {
            return result
        }

        setLyricsSupplementLoading(
            pronunciation: loading.pronunciation,
            translation: loading.translation,
            furigana: lyricsSupplementFuriganaLoading
        )
        let response = await aiRepository.loadSupplements(
            track: track,
            baseResult: base,
            settings: snapshot,
            sourceLangOverride: sourceLang,
            bypassCache: bypassCache
        ) { [weak self] partial in
            self?.applyAiSupplementPartial(track: track, response: partial)
        }
        if Task.isCancelled { return result }
        appendLogs(response.logs)
        result = response.result
        setLyricsSupplementLoading(pronunciation: false, translation: false, furigana: lyricsSupplementFuriganaLoading)
        return result
    }

    private func requestMetadataTranslation(track: TrackSnapshot, base: LyricsResult, bypassCache: Bool) {
        metadataTranslationTask?.cancel()
        guard track.hasUsableMetadata, !track.isSpotifyDjSegment else {
            metadataTranslation = nil
            return
        }

        let snapshot = settings.snapshot
        let sourceLang = effectiveSelectedSourceLang(lines: base.lines)
        let targetLang = snapshot.resolveTargetLanguage(sourceLang: sourceLang)
        guard snapshot.metadataTranslationEnabled,
              !AppSettings.isSameLanguage(sourceLang, targetLang),
              snapshot.hasApiKey else {
            metadataTranslation = nil
            return
        }

        let trackKey = track.stableKey
        metadataTranslationTask = Task { [weak self] in
            guard let self else { return }
            let response = await aiRepository.loadMetadataTranslation(
                track: track,
                settings: snapshot,
                sourceLangOverride: sourceLang,
                bypassCache: bypassCache
            )
            if Task.isCancelled { return }
            appendLogs(response.logs)
            guard currentTrack?.stableKey == trackKey,
                  let translation = response.translation else {
                return
            }

            let currentSnapshot = settings.snapshot
            let currentSource = effectiveSelectedSourceLang(lines: baseLyricsResult.lines)
            let currentTarget = currentSnapshot.resolveTargetLanguage(sourceLang: currentSource)
            guard currentSnapshot.metadataTranslationEnabled,
                  !AppSettings.isSameLanguage(currentSource, currentTarget),
                  AppSettings.normalizeLanguageCode(currentSource).caseInsensitiveCompare(translation.sourceLang) == .orderedSame,
                  AppSettings.normalizeLanguageCode(currentTarget).caseInsensitiveCompare(translation.targetLang) == .orderedSame else {
                return
            }
            metadataTranslation = translation
        }
    }

    private func applyAiSupplementPartial(track: TrackSnapshot, response: AiLyricsRepository.SupplementResponse) {
        guard !Task.isCancelled, currentTrack?.stableKey == track.stableKey else { return }
        lyricsResult = mergeCurrentFurigana(into: response.result, trackKey: track.stableKey)
        setLyricsSupplementLoading(
            pronunciation: response.pronunciationLoading,
            translation: response.translationLoading,
            furigana: lyricsSupplementFuriganaLoading
        )
    }

    private func loadFuriganaIfNeeded(track: TrackSnapshot, base: LyricsResult, bypassCache: Bool) async -> LyricsResult {
        guard track.hasUsableMetadata, settings.snapshot.japaneseFuriganaEnabled else {
            setLyricsSupplementLoading(
                pronunciation: lyricsSupplementPronunciationLoading,
                translation: lyricsSupplementTranslationLoading,
                furigana: false
            )
            return base
        }
        guard shouldLoadFurigana(base: base) else {
            setLyricsSupplementLoading(
                pronunciation: lyricsSupplementPronunciationLoading,
                translation: lyricsSupplementTranslationLoading,
                furigana: false
            )
            return base
        }
        setLyricsSupplementLoading(
            pronunciation: lyricsSupplementPronunciationLoading,
            translation: lyricsSupplementTranslationLoading,
            furigana: true
        )
        let furigana = await furiganaRepository.loadFurigana(track: track, baseResult: base, bypassCache: bypassCache)
        if Task.isCancelled { return base }
        appendLogs(furigana.logs)
        if !furigana.hadError, currentTrack?.stableKey == track.stableKey {
            currentFuriganaKey = track.stableKey
            currentFuriganaResult = furigana.result
            lyricsResult = mergeFuriganaIntoResult(lyricsResult, furiganaSource: furigana.result)
        }
        setLyricsSupplementLoading(
            pronunciation: lyricsSupplementPronunciationLoading,
            translation: lyricsSupplementTranslationLoading,
            furigana: false
        )
        return furigana.result
    }

    private func shouldLoadFurigana(base: LyricsResult) -> Bool {
        guard !base.lines.isEmpty else { return false }
        let payload = supplementDetectionPayload(lines: base.lines)
        guard !payload.trimmed.isEmpty else { return false }
        return effectiveSelectedSourceLang(lines: base.lines) == "ja" && containsKanji(payload)
    }

    private func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3400...0x4dbf).contains(Int(scalar.value))
                || (0x4e00...0x9fff).contains(Int(scalar.value))
                || (0xf900...0xfaff).contains(Int(scalar.value))
        }
    }

    private func mergeCurrentFurigana(into target: LyricsResult, trackKey: String) -> LyricsResult {
        guard currentFuriganaKey == trackKey, let currentFuriganaResult else { return target }
        return mergeFuriganaIntoResult(target, furiganaSource: currentFuriganaResult)
    }

    private func mergeFuriganaIntoResult(_ target: LyricsResult, furiganaSource: LyricsResult) -> LyricsResult {
        guard !target.lines.isEmpty else { return target }
        let lines = target.lines.enumerated().map { index, targetLine in
            let sourceLine = index < furiganaSource.lines.count ? furiganaSource.lines[index] : nil
            return mergeFuriganaIntoLine(targetLine, furiganaSource: sourceLine)
        }
        return LyricsResult(
            lines: lines,
            providerLabel: target.providerLabel,
            detail: target.detail,
            karaoke: target.karaoke,
            isrc: target.isrc,
            spotifyTrackId: target.spotifyTrackId,
            contributors: target.contributors
        )
    }

    private func mergeFuriganaIntoLine(_ target: LyricsLine, furiganaSource: LyricsLine?) -> LyricsLine {
        let lineFurigana = IvLyricsUtilities.firstNonEmpty(furiganaSource?.furiganaText, target.furiganaText)
        guard !target.vocalParts.isEmpty else {
            return target.withSupplements(
                pronunciation: target.pronunciationText,
                translation: target.translationText,
                furigana: lineFurigana
            )
        }

        let parts = target.vocalParts.enumerated().map { index, targetPart in
            let sourcePart = index < (furiganaSource?.vocalParts.count ?? 0)
                ? furiganaSource?.vocalParts[index]
                : nil
            var partFurigana = IvLyricsUtilities.firstNonEmpty(sourcePart?.furiganaText, targetPart.furiganaText)
            if partFurigana.isEmpty, target.vocalParts.count == 1 {
                partFurigana = lineFurigana
            }
            return targetPart.withSupplements(
                pronunciation: targetPart.pronunciationText,
                translation: targetPart.translationText,
                furigana: partFurigana
            )
        }
        return LyricsLine(
            startTimeMs: target.startTimeMs,
            endTimeMs: target.endTimeMs,
            text: target.text,
            syllables: target.syllables,
            speaker: target.speaker,
            speakerColor: target.speakerColor,
            speakerFallback: target.speakerFallback,
            kind: target.kind,
            vocalParts: parts,
            pronunciationText: target.pronunciationText,
            translationText: target.translationText,
            furiganaText: lineFurigana
        )
    }

    private func cancelLyricsLoadTask() {
        lyricsLoadRequestID = UUID()
        loadTask?.cancel()
        loadTask = nil
        metadataTranslationTask?.cancel()
        metadataTranslationTask = nil
        furiganaRefreshTask?.cancel()
        furiganaRefreshTask = nil
        resetCurrentFurigana()
        resetLyricsSupplementLoading()
    }

    private func isLyricsLoadCurrent(_ requestID: UUID, trackKey: String) -> Bool {
        !Task.isCancelled
            && lyricsLoadRequestID == requestID
            && currentTrack?.stableKey == trackKey
    }

    private func resetCurrentFurigana() {
        currentFuriganaKey = ""
        currentFuriganaResult = nil
    }

    private func resetLyricsSupplementLoading() {
        setLyricsSupplementLoading(pronunciation: false, translation: false, furigana: false)
    }

    private func setLyricsSupplementLoading(pronunciation: Bool, translation: Bool, furigana: Bool) {
        lyricsSupplementPronunciationLoading = pronunciation
        lyricsSupplementTranslationLoading = translation
        lyricsSupplementFuriganaLoading = furigana
        aiLyricsGenerating = pronunciation || translation
    }

    private func aiSupplementLoadingState(
        track: TrackSnapshot,
        base: LyricsResult,
        snapshot: AppSettings.Snapshot,
        sourceLang: String
    ) -> (pronunciation: Bool, translation: Bool) {
        guard track.hasUsableMetadata,
              !base.lines.isEmpty,
              snapshot.enabled,
              snapshot.hasApiKey else {
            return (false, false)
        }
        let payload = supplementDetectionPayload(lines: base.lines)
        guard !payload.trimmed.isEmpty else {
            return (false, false)
        }
        let rule = snapshot.ruleForSource(sourceLang)
        let targetLang = snapshot.resolveTargetLanguage(sourceLang: sourceLang)
        let translation = rule.translationEnabled && !snapshot.shouldSkipTranslation(sourceLang: sourceLang, resolvedTargetLang: targetLang)
        return (rule.pronunciationEnabled, translation)
    }

    private func effectiveSelectedSourceLang(lines: [LyricsLine]) -> String {
        selectedRuleSourceLang.caseInsensitiveCompare("auto") == .orderedSame
            ? detectedSourceLang(lines: lines)
            : AppSettings.normalizeSourceLanguageKey(selectedRuleSourceLang)
    }

    private func detectedSourceLang(lines: [LyricsLine]) -> String {
        let payload = supplementDetectionPayload(lines: lines)
        let normalized = AppSettings.normalizeLanguageCode(AiLyricsRepository.detectLanguage(payload))
        return normalized.isEmpty ? "en" : normalized
    }

    private func supplementDetectionPayload(lines: [LyricsLine]) -> String {
        var values: [String] = []
        for line in lines {
            let parts = LyricsTimelineDisplayBuilder.orderedVocalParts(line.vocalParts)
                .map { LyricsTimelineDisplayBuilder.vocalPartDisplayText($0).trimmed }
                .filter { !$0.isEmpty }
            if parts.count > 1 {
                values.append(contentsOf: parts)
            } else {
                let text = line.text.trimmed.isEmpty ? parts.joined(separator: " / ") : line.text.trimmed
                if !text.isEmpty {
                    values.append(text)
                }
            }
        }
        return values.joined(separator: "\n")
    }

    private func applyEarlySpotifyLyricsMetadata(_ metadata: LyricsRepository.ResolvedSpotifyMetadata) {
        guard var latestTrack = currentTrack, latestTrack.stableKey == metadata.trackKey else { return }
        let normalizedIsrc = TrackSnapshot.normalizeIsrc(metadata.isrc)
        let safeSpotifyTrackId = metadata.spotifyTrackId.trimmed
        let metadataChanged = (!normalizedIsrc.isEmpty && normalizedIsrc != latestTrack.isrc)
            || (!safeSpotifyTrackId.isEmpty && safeSpotifyTrackId != latestTrack.trackId)

        if !normalizedIsrc.isEmpty {
            latestTrack.isrc = normalizedIsrc
            inputIsrc = normalizedIsrc
        }
        if !safeSpotifyTrackId.isEmpty {
            inputSpotifyId = safeSpotifyTrackId
        }
        if let artworkURL = metadata.artworkURL, artworkURL != latestTrack.artworkURL {
            latestTrack.artworkURL = artworkURL
            appendLog("spotify artwork applied: \(artworkURL.absoluteString)")
        }
        currentTrack = latestTrack

        guard metadataChanged, !normalizedIsrc.isEmpty else { return }
        appendLog("youtube background: metadata ready, preloading video isrc=\(normalizedIsrc)" + (safeSpotifyTrackId.isEmpty ? "" : " / trackId=\(safeSpotifyTrackId)"))
        scheduleYouTubeBackgroundLoad(
            track: latestTrack,
            result: youtubeMetadataResult(source: lyricsResult, isrc: normalizedIsrc, spotifyTrackId: safeSpotifyTrackId)
        )
    }

    private func scheduleYouTubeBackgroundLoad(track: TrackSnapshot, result: LyricsResult) {
        youtubeBackgroundLoadTask?.cancel()
        youtubeBackgroundLoadTask = Task { @MainActor [weak self] in
            await self?.loadYouTubeIfNeeded(track: track, result: result)
        }
    }

    private func resetYouTubeBackgroundForTrack() {
        youtubeBackgroundLoadTask?.cancel()
        youtubeBackgroundLoadTask = nil
        currentYouTubeBackgroundRequestKey = ""
        currentYouTubeBackgroundLoading = false
        youtubeInfo = nil
    }

    private func youtubeMetadataResult(source: LyricsResult, isrc: String, spotifyTrackId: String) -> LyricsResult {
        let normalizedIsrc = TrackSnapshot.normalizeIsrc(isrc)
        let safeSpotifyTrackId = spotifyTrackId.trimmed
        if normalizedIsrc == source.isrc && safeSpotifyTrackId == source.spotifyTrackId {
            return source
        }
        return LyricsResult(
            lines: source.lines,
            providerLabel: source.providerLabel,
            detail: source.detail,
            karaoke: source.karaoke,
            isrc: normalizedIsrc,
            spotifyTrackId: safeSpotifyTrackId,
            contributors: source.contributors
        )
    }

    private func loadYouTubeIfNeeded(track: TrackSnapshot, result: LyricsResult) async {
        guard settings.effectiveBackgroundSettings(trackKey: track.stableKey).mode == AppSettings.backgroundVideo else {
            currentYouTubeBackgroundRequestKey = ""
            currentYouTubeBackgroundLoading = false
            youtubeInfo = nil
            return
        }
        let isrc = IvLyricsUtilities.firstNonEmpty(result.isrc, track.isrc)
        guard !isrc.isEmpty else {
            appendLog("youtube background: waiting for ISRC")
            return
        }
        let requestKey = "isrc:\(isrc)"
        if requestKey == currentYouTubeBackgroundRequestKey && (currentYouTubeBackgroundLoading || youtubeInfo != nil) {
            return
        }
        currentYouTubeBackgroundRequestKey = requestKey
        currentYouTubeBackgroundLoading = true
        youtubeInfo = nil
        do {
            let loaded = try await youtubeRepository.load(track: track, lyricsResult: result)
            if Task.isCancelled { return }
            guard requestKey == currentYouTubeBackgroundRequestKey else { return }
            currentYouTubeBackgroundLoading = false
            youtubeInfo = loaded.info
            appendLogs(loaded.logs)
            appendLog("youtube background loaded: \(loaded.info.youtubeVideoId)" + (loaded.fromCache ? " / cache" : ""))
        } catch {
            guard requestKey == currentYouTubeBackgroundRequestKey else { return }
            currentYouTubeBackgroundLoading = false
            youtubeInfo = nil
            appendLog(error.localizedDescription)
        }
    }

    private func fetchSyncContributorProfileURL(userHash: String, fallback: URL) async throws -> URL {
        var components = URLComponents(string: creatorProfileEndpoint)!
        components.queryItems = [URLQueryItem(name: "userHash", value: userHash)]
        guard let url = components.url else { return fallback }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ivLyrics-Android/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue(syncDataSpotifyOrigin, forHTTPHeaderField: "Origin")
        request.setValue(syncDataSpotifyReferer, forHTTPHeaderField: "Referer")
        request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return fallback
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              boolValue(root["success"], fallback: false),
              let payload = root["data"] as? [String: Any] else {
            return fallback
        }
        let account = payload["account"] as? [String: Any]
        let identifier = IvLyricsUtilities.firstNonEmpty(
            stringValue(account?["username"]),
            stringValue(payload["nickname"]),
            stringValue(payload["userHash"])
        )
        return identifier.isEmpty ? fallback : syncContributorProfileURL(identifier: identifier)
    }

    private func syncContributorProfileURL(identifier: String) -> URL {
        let safeIdentifier = identifier.replacingOccurrences(of: #"^@+"#, with: "", options: .regularExpression).trimmed
        guard !safeIdentifier.isEmpty else { return URL(string: "https://lyrics.ivl.is")! }
        return URL(string: "https://lyrics.ivl.is/@\(IvLyricsUtilities.urlEncode(safeIdentifier))") ?? URL(string: "https://lyrics.ivl.is")!
    }

    private func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmed }
        if let value = value as? NSNumber { return value.stringValue.trimmed }
        return ""
    }

    private func boolValue(_ value: Any?, fallback: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            let normalized = value.trimmed.lowercased()
            if ["true", "1", "yes"].contains(normalized) { return true }
            if ["false", "0", "no"].contains(normalized) { return false }
        }
        return fallback
    }

    private func activeLineIndex(at position: Int64) -> Int {
        guard !lyricsResult.lines.isEmpty else { return -1 }
        var candidate = 0
        for index in lyricsResult.lines.indices {
            let line = lyricsResult.lines[index]
            if position >= line.startTimeMs {
                candidate = index
            }
            if line.endTimeMs > line.startTimeMs, position >= line.startTimeMs, position < line.endTimeMs {
                return index
            }
        }
        return candidate
    }

    private static func firstLyricTimeMs(in result: LyricsResult) -> Int64 {
        var best = Int64.max
        for line in result.lines {
            if !line.vocalParts.isEmpty {
                for part in line.vocalParts where part.startTimeMs >= 0 {
                    best = min(best, part.startTimeMs)
                }
            } else if line.isTimed {
                best = min(best, line.startTimeMs)
            }
        }
        return best == Int64.max ? 0 : best
    }

    private func startClock() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.nowPositionMs = self.currentTrack?.positionNow() ?? 0
                self.updatePictureInPictureState()
            }
        }
        timer?.tolerance = 0.008
    }

    private func updatePictureInPictureState(force: Bool = false) {
        guard force || pictureInPictureController.needsStateUpdates else { return }
        pictureInPictureController.update(
            track: currentTrack,
            lyrics: lyricsResult,
            positionMs: adjustedPositionMs,
            title: titleText,
            artist: artistText,
            settings: settings.snapshot
        )
    }

    private func startBluetoothRouteMonitoring() {
        refreshBluetoothAudioRoute(deviceChanged: false)
        #if os(iOS)
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshBluetoothAudioRoute(deviceChanged: true)
            }
        }
        #endif
    }

    private func refreshBluetoothAudioRoute(deviceChanged: Bool) {
        let previousKey = bluetoothAudioDeviceKey
        let device = currentBluetoothAudioDevice()
        bluetoothAudioDeviceKey = device?.key ?? ""
        bluetoothAudioDeviceName = device?.name ?? ""
        bluetoothOffsetMs = bluetoothAudioDeviceKey.isEmpty ? 0 : settings.bluetoothSyncOffsetMs(bluetoothAudioDeviceKey)
        if deviceChanged || previousKey != bluetoothAudioDeviceKey {
            appendLog(bluetoothAudioDeviceKey.isEmpty
                ? "bluetooth audio offset: no bluetooth output detected"
                : "bluetooth audio offset: device=\"\(bluetoothAudioDeviceName)\" / offset=\(bluetoothOffsetMs)ms")
        }
    }

    private func currentBluetoothAudioDevice() -> BluetoothAudioDevice? {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let devices = outputs.compactMap { port -> BluetoothAudioDevice? in
            guard Self.isBluetoothAudioPort(port.portType) else { return nil }
            let name = port.portName.trimmed.isEmpty ? Self.bluetoothAudioPortLabel(port.portType) : port.portName.trimmed
            let keyName = (name.isEmpty ? port.uid : name)
                .lowercased()
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return BluetoothAudioDevice(key: "type:\(port.portType.rawValue)|name:\(keyName)", name: name.isEmpty ? "Unknown Bluetooth Device" : name)
        }
        return devices.first { $0.key.contains(AVAudioSession.Port.bluetoothA2DP.rawValue) || $0.key.contains(AVAudioSession.Port.bluetoothLE.rawValue) }
            ?? devices.first
        #else
        return nil
        #endif
    }

    #if os(iOS)
    private static func isBluetoothAudioPort(_ port: AVAudioSession.Port) -> Bool {
        port == .bluetoothA2DP || port == .bluetoothHFP || port == .bluetoothLE
    }

    private static func bluetoothAudioPortLabel(_ port: AVAudioSession.Port) -> String {
        switch port {
        case .bluetoothA2DP:
            return "Bluetooth A2DP"
        case .bluetoothHFP:
            return "Bluetooth HFP"
        case .bluetoothLE:
            return "Bluetooth LE"
        default:
            return "Bluetooth"
        }
    }
    #endif

    private func finishPollinationsLogin(_ accessToken: String) {
        pollinationsAuthInFlight = false
        pollinationsAuthVerificationURL = nil
        pollinationsAuthUserCode = ""
        settings.pollinationsAccessToken = accessToken.trimmed
        pollinationsAuthStatus = settings.t("pollinations.status_saved")
        appendLog("pollinations auth: connected through device login")
        showSavedToast(settings.t("pollinations.toast_connected"))
        if currentTrack?.hasUsableMetadata == true {
            reloadLyrics(bypassCache: true)
        }
    }

    private func failPollinationsLogin(_ error: Error) {
        pollinationsAuthInFlight = false
        pollinationsAuthVerificationURL = nil
        pollinationsAuthUserCode = ""
        let detail = error.localizedDescription.trimmed.isEmpty ? "unknown error" : error.localizedDescription.trimmed
        pollinationsAuthStatus = settings.tf("pollinations.status_failed_format", detail)
        appendLog("pollinations auth failed: \(detail)")
        showSavedToast(settings.t("pollinations.toast_failed"))
    }

    private func firstPollinationsAuthToken() -> String {
        let loginToken = settings.pollinationsAccessToken.trimmed
        if !loginToken.isEmpty {
            return loginToken
        }
        let manual = settings.apiKeys.trimmed
        guard !manual.isEmpty else { return "" }
        if manual.hasPrefix("["),
           let data = manual.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String],
           let first = array.map(\.trimmed).first(where: { !$0.isEmpty }) {
            return first
        }
        return manual.split { $0 == "\n" || $0 == "," }.map { String($0).trimmed }.first(where: { !$0.isEmpty }) ?? ""
    }

    private func spotifyCredentialsSourceKey(clientId: String, clientSecret: String) -> String {
        let safeClientId = clientId.trimmed
        let safeClientSecret = clientSecret.trimmed
        guard !safeClientId.isEmpty, !safeClientSecret.isEmpty else {
            return "spotify-client:missing"
        }
        return "spotify-client:\(safeClientId):\(IvLyricsUtilities.sha256(safeClientId + "\n" + safeClientSecret).prefix(12))"
    }

    private func maskAccessToken(_ token: String) -> String {
        let value = token.trimmed
        guard value.count > 12 else { return settings.t("pollinations.configured") }
        return String(value.prefix(5)) + "..." + String(value.suffix(4))
    }

    private func appendLog(_ message: String) {
        let text = message.trimmed
        guard !text.isEmpty else { return }
        logs.append(text)
        if logs.count > 160 {
            logs.removeFirst(logs.count - 160)
        }
    }

    private func appendLogs(_ messages: [String]) {
        for message in messages {
            appendLog(message)
        }
    }

    private func saveManualInputs() {
        defaults.set(inputTitle.trimmed, forKey: "manual_track_title")
        defaults.set(inputArtist.trimmed, forKey: "manual_track_artist")
        defaults.set(inputAlbum.trimmed, forKey: "manual_track_album")
        defaults.set(inputDuration.trimmed, forKey: "manual_track_duration")
        defaults.set(inputSpotifyId.trimmed, forKey: "manual_track_spotify_id")
        defaults.set(inputIsrc.trimmed, forKey: "manual_track_isrc")
    }

    private func parseDurationMs(_ value: String) -> Int64 {
        let text = value.trimmed
        guard !text.isEmpty else { return 0 }
        if text.contains(":") {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 {
                return Int64(((parts[0] * 60) + parts[1]) * 1000)
            }
            if parts.count == 3 {
                return Int64(((parts[0] * 3600) + (parts[1] * 60) + parts[2]) * 1000)
            }
        }
        if let seconds = Double(text) {
            return Int64(max(0, seconds) * 1000)
        }
        return 0
    }

    private func formatDurationInput(_ ms: Int64) -> String {
        let total = max(0, Int((Double(ms) / 1000.0).rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct BluetoothAudioDevice {
    var key: String
    var name: String
}
