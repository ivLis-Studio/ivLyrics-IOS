import SwiftUI
import Foundation

#if os(iOS)
import WebKit

struct YouTubeBackdropView: UIViewRepresentable {
    private static let syncIntervalSeconds: TimeInterval = 0.5
    private static let htmlOrigin = "https://xpui.app.spotify.com/"
    private static let commandFeedbackSuppressionScript = #"""
    (() => {
      const id = 'ivlyrics-youtube-command-feedback-style';
      if (document.getElementById(id)) return;
      const style = document.createElement('style');
      style.id = id;
      style.textContent = '.ytp-bezel,.ytp-bezel-text-wrapper,.ytp-pause-overlay,.ytwPlayerMiddleControlsHost{display:none!important;visibility:hidden!important;opacity:0!important}';
      document.documentElement.appendChild(style);
    })();
    """#
    private static let adURLPatterns = [
        "doubleclick.net",
        "googlesyndication.com",
        "googleads.g.doubleclick.net",
        "tpc.googlesyndication.com",
        "pubads.g.doubleclick.net",
        "securepubads.g.doubleclick.net",
        "gstaticadssl.googleapis.com",
        "s0.2mdn.net",
        "youtube.com/pagead",
        "youtube.com/ptracking",
        "youtubei/v1/log_event",
        "youtube.com/yva_"
    ]
    private static let dynamicAdURLPattern = #"(?:gvt\d+\.com/ads|yt\d?\.ggpht\.com/ad|ytimg\.com/.*ad|yt3\.ggpht\.com/ytc/.*ad)"#
    private static let dynamicAdURLRegex = try? NSRegularExpression(pattern: dynamicAdURLPattern)

    var info: YouTubeVideoInfo
    var playerSeconds: Double
    var playing: Bool
    var firstLyricSeconds: Double
    var offsetSeconds: Double
    var hasCaptionStartTime: Bool
    var captionStartTimeSeconds: Double
    var autoMatchedUnknownCaptionStart: Bool
    var brightness: Int
    var blur: Int
    var videoScale: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.commandFeedbackSuppressionScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController.add(context.coordinator, name: "ivLyricsYouTube")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.alpha = 0
        view.scrollView.isScrollEnabled = false
        view.loadHTMLString(Self.html(videoId: info.youtubeVideoId, videoScale: videoScale), baseURL: URL(string: Self.htmlOrigin))
        context.coordinator.webView = view
        context.coordinator.videoId = info.youtubeVideoId
        context.coordinator.videoScale = videoScale
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.videoId != info.youtubeVideoId {
            context.coordinator.videoId = info.youtubeVideoId
            context.coordinator.videoScale = videoScale
            context.coordinator.playerReady = false
            context.coordinator.visibleState = false
            webView.alpha = 0
            webView.loadHTMLString(Self.html(videoId: info.youtubeVideoId, videoScale: videoScale), baseURL: URL(string: Self.htmlOrigin))
        } else if context.coordinator.videoScale != videoScale {
            context.coordinator.videoScale = videoScale
            webView.evaluateJavaScript("document.documentElement.style.setProperty('--video-scale','\(Self.cssScale(videoScale))');")
        }
        let now = Date().timeIntervalSince1970
        context.coordinator.setPlaybackState(playing: playing)
        context.coordinator.updateVisibility(for: webView, visible: context.coordinator.playerReady && playing)
        if now - context.coordinator.lastSyncAt > Self.syncIntervalSeconds
            || abs(context.coordinator.lastPlayerSeconds - playerSeconds) > 1.2
            || abs(context.coordinator.lastOffsetSeconds - offsetSeconds) > 0.01
            || abs(context.coordinator.lastFirstLyricSeconds - firstLyricSeconds) > 0.01 {
            context.coordinator.lastSyncAt = now
            context.coordinator.lastPlayerSeconds = playerSeconds
            context.coordinator.lastOffsetSeconds = offsetSeconds
            context.coordinator.lastFirstLyricSeconds = firstLyricSeconds
            let command = """
            window.ivLyricsSyncVideo(\(Self.jsNumber(playerSeconds)),\(playing ? "true" : "false"),\(Self.jsNumber(firstLyricSeconds)),\(Self.jsNumber(offsetSeconds)),\(hasCaptionStartTime ? "true" : "false"),\(Self.jsNumber(captionStartTimeSeconds)),\(autoMatchedUnknownCaptionStart ? "true" : "false"),true,true);
            """
            webView.evaluateJavaScript(command)
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "ivLyricsYouTube")
        uiView.navigationDelegate = nil
        uiView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var videoId = ""
        var videoScale = 100
        var lastSyncAt: TimeInterval = 0
        var lastPlayerSeconds: Double = 0
        var lastOffsetSeconds: Double = 0
        var lastFirstLyricSeconds: Double = 0
        var playing = false
        var playerReady = false
        var visibleState = false

        func setPlaybackState(playing nextPlaying: Bool) {
            if nextPlaying != playing {
                lastSyncAt = 0
            }
            playing = nextPlaying
        }

        private func pausePlayer() {
            webView?.evaluateJavaScript("try{if(player&&player.pauseVideo){player.pauseVideo();}}catch(e){}")
        }

        func updateVisibility(for webView: WKWebView?, visible: Bool) {
            guard visibleState != visible else { return }
            visibleState = visible
            guard let target = webView ?? self.webView else { return }
            UIView.animate(withDuration: visible ? 0.28 : 0.18) {
                target.alpha = visible ? 1 : 0
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ivLyricsYouTube" else { return }
            if (message.body as? String) == "ready" {
                playerReady = true
                updateVisibility(for: webView, visible: playing)
                if !playing {
                    pausePlayer()
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url?.absoluteString ?? ""
            decisionHandler(YouTubeBackdropView.shouldBlockURL(url) ? .cancel : .allow)
        }
    }

    private static func html(videoId: String, videoScale: Int) -> String {
        let safeVideoId = jsSingleQuotedContent(videoId)
        return #"""
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent;}
            :root{--video-scale:\#(cssScale(videoScale));}
            #wrap{position:fixed;inset:0;overflow:hidden;background:transparent;}
            #stage{position:absolute;top:50%;left:50%;width:100vw;height:56.25vw;min-width:177.7778vh;min-height:100vh;transform:translate3d(-50%,-50%,0) scale(var(--video-scale));overflow:hidden;background:transparent;transition:transform .18s ease;will-change:transform;}
            #player,#stage iframe{position:absolute!important;inset:0!important;width:100%!important;height:100%!important;transform:none!important;pointer-events:none!important;border:0!important;outline:0!important;}
            *{-webkit-tap-highlight-color:transparent!important;user-select:none!important;-webkit-user-select:none!important;}
          </style>
        </head>
        <body>
          <div id="wrap"><div id="stage"><div id="player"></div></div></div>
          <script src="https://www.youtube.com/iframe_api"></script>
          <script>
            var player=null,ready=false,lastCaptionDisable=0,lastSeekAt=0,lastDesired={videoId:'\#(safeVideoId)',startSeconds:0};
            var adPatterns=[/doubleclick\.net/i,/googlesyndication\.com/i,/googleads\.g\.doubleclick\.net/i,/pagead(?!.*youtube\.com\/iframe)/i,/tpc\.googlesyndication\.com/i,/pubads\.g\.doubleclick\.net/i,/securepubads\.g\.doubleclick\.net/i,/gvt\d+\.com\/ads/i,/manifest\.googlevideo\.com\/api\/manifest\/ads/i,/googlevideo\.com\/videoplayback.*[&?](ctier|oad|adformat)=/i,/googlevideo\.com\/initplayback.*[&?](ctier|oad|adformat)=/i,/youtube\.com\/pagead/i,/youtube\.com\/ptracking/i,/youtube\.com\/api\/stats\/(ads|qoe|watchtime|playback)/i,/youtubei\/v1\/log_event/i,/youtubei\/v1\/player.*adformat/i,/youtube\.com\/get_video_info.*adformat/i,/youtube\.com\/yva_/i,/yt\d?\.ggpht\.com\/ad/i,/ytimg\.com\/.*ad/i,/yt3\.ggpht\.com\/ytc\/.*ad/i,/s0\.2mdn\.net/i,/gstaticadssl\.googleapis\.com/i];
            function isAdUrl(u){try{u=(typeof u==='string'?u:(u&&u.url)||'');return !!u&&adPatterns.some(function(p){return p.test(u);});}catch(e){return false;}}
            (function patchRequests(){try{var of=window.fetch;if(of&&!of.__ivl){var nf=function(r,i){var u=typeof r==='string'?r:(r&&r.url);if(isAdUrl(u))return Promise.resolve(new Response('',{status:204,statusText:'No Content'}));return of.call(this,r,i);};nf.__ivl=1;window.fetch=nf;}}catch(e){}
            try{var xo=XMLHttpRequest.prototype.open,xs=XMLHttpRequest.prototype.send;XMLHttpRequest.prototype.open=function(m,u){this.__ivlUrl=u;return xo.apply(this,arguments);};XMLHttpRequest.prototype.send=function(b){if(isAdUrl(this.__ivlUrl)){setTimeout(()=>{try{this.dispatchEvent(new Event('error'));this.onerror&&this.onerror(new Event('error'));}catch(e){}},0);return;}return xs.apply(this,arguments);};}catch(e){}
            try{var sb=navigator.sendBeacon&&navigator.sendBeacon.bind(navigator);if(sb){navigator.sendBeacon=function(u,d){return isAdUrl(u)?true:sb(u,d);};}}catch(e){}
            try{var oo=window.open;if(oo){window.open=function(u,t,f){return isAdUrl(u)?null:oo.call(this,u,t,f);};}}catch(e){}})();
            function disableCaptions(){try{if(player&&player.unloadModule){player.unloadModule('captions');player.unloadModule('cc');}}catch(e){}
            try{if(player&&player.setOption){player.setOption('captions','track',{});player.setOption('cc','track',{});}}catch(e){}}
            function sanitizeIframe(){try{var f=player&&player.getIframe&&player.getIframe();if(!f)return;f.setAttribute('referrerpolicy','origin');f.setAttribute('allow','autoplay; encrypted-media; picture-in-picture');f.setAttribute('tabindex','-1');f.setAttribute('aria-hidden','true');f.style.position='absolute';f.style.inset='0';f.style.width='100%';f.style.height='100%';f.style.transform='none';f.style.pointerEvents='none';f.style.border='0';}catch(e){}}
            function isAdPlayback(){try{if(player&&player.getAdState&&player.getAdState()===1)return true;}catch(e){}try{return [105,106,107,108,109,110,111].indexOf(player&&player.getPlayerState&&player.getPlayerState())>=0;}catch(e){return false;}}
            function reloadDesired(){try{if(player&&player.loadVideoById&&lastDesired&&lastDesired.videoId){player.loadVideoById({videoId:lastDesired.videoId,startSeconds:lastDesired.startSeconds||0,suggestedQuality:'default'});return true;}}catch(e){}return false;}
            function suppressAds(){if(!isAdPlayback())return;try{player.mute&&player.mute();}catch(e){}try{player.setPlaybackRate&&player.setPlaybackRate(16);}catch(e){}try{player.skipAd&&player.skipAd();return;}catch(e){}try{var d=player.getDuration&&player.getDuration();if(d>0){player.seekTo(Math.max(d-0.1,0),true);return;}}catch(e){}reloadDesired();}
            function restorePlaybackRate(){try{if(player&&player.setPlaybackRate&&player.getPlaybackRate&&player.getPlaybackRate()!==1)player.setPlaybackRate(1);}catch(e){}}
            function onYouTubeIframeAPIReady(){player=new YT.Player('player',{host:'https://www.youtube-nocookie.com',videoId:'\#(safeVideoId)',
            playerVars:{autoplay:1,controls:0,disablekb:1,fs:0,rel:0,iv_load_policy:3,cc_load_policy:0,mute:1,playsinline:1,modestbranding:1,autohide:1,showinfo:0,enablecastapi:0,allowfullscreen:0,disable_polymer:1,suppress_ads:1,adformat:'0_0',widget_referrer:'https://xpui.app.spotify.com',origin:'https://xpui.app.spotify.com',fflags:'disable_persistent_ads=true&kevlar_allow_multistep_video_ads=false&enable_desktop_ad_controls=false&html5_disable_ads=true&disable_new_pause_state3_player_ads=true&player_ads_enable_gcf=false&web_player_disable_afa=true&preskip_button_style_ads_backend=false&html5_player_enable_ads_client=false'},
            events:{onReady:function(e){player=e.target;ready=true;sanitizeIframe();try{player.mute();player.playVideo();}catch(x){}disableCaptions();setTimeout(disableCaptions,250);setTimeout(disableCaptions,1000);setTimeout(disableCaptions,2500);try{window.webkit.messageHandlers.ivLyricsYouTube.postMessage('ready');}catch(x){}},
            onStateChange:function(e){sanitizeIframe();disableCaptions();suppressAds();if(!isAdPlayback())restorePlaybackRate();},onError:function(){reloadDesired();}}});setInterval(function(){if(player&&ready){sanitizeIframe();suppressAds();}},400);}
            window.ivLyricsSyncVideo=function(playerSeconds,playing,firstLyricSeconds,offsetSeconds,hasCaption,captionStart,autoUnknown,enabled,allowHardSync){
            if(!enabled||!player||!ready||!player.getPlayerState)return;
            try{var now=Date.now();if(now-lastCaptionDisable>5000){lastCaptionDisable=now;disableCaptions();}
            suppressAds();
            var extra=0;if(hasCaption&&!autoUnknown){extra=Number(captionStart||0)-Number(firstLyricSeconds||0);}
            var target=Number(playerSeconds||0)+extra+Number(offsetSeconds||0);
            if(target<0)return;
            if(player.getDuration){var duration=player.getDuration();if(duration>0&&target>=duration){target=target%duration;}}
            lastDesired={videoId:'\#(safeVideoId)',startSeconds:target};
            var state=player.getPlayerState();
            if(playing){if(state!==1&&state!==3&&!isAdPlayback()){player.playVideo();}var current=player.getCurrentTime?player.getCurrentTime():0;var diff=Math.abs(current-target);if(allowHardSync&&diff>3.25&&(diff>6||now-lastSeekAt>2200)){lastSeekAt=now;player.seekTo(target,true);}}
            else{if(state===1||state===3){player.pauseVideo();}}
            }catch(e){}};
          </script>
        </body>
        </html>
        """#
    }

    private static func cssScale(_ value: Int) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), Double(min(180, max(100, value))) / 100.0)
    }

    private static func jsNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func jsSingleQuotedContent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func shouldBlockURL(_ url: String) -> Bool {
        let normalized = url.lowercased()
        if normalized.contains("pagead"), !normalized.contains("youtube.com/iframe") {
            return true
        }
        if normalized.contains("googlevideo.com/videoplayback"),
           normalized.contains("ctier=") || normalized.contains("oad=") || normalized.contains("adformat=") {
            return true
        }
        if normalized.contains("googlevideo.com/initplayback"),
           normalized.contains("ctier=") || normalized.contains("oad=") || normalized.contains("adformat=") {
            return true
        }
        if normalized.contains("youtube.com/api/stats/ads")
            || normalized.contains("youtube.com/api/stats/qoe")
            || normalized.contains("youtube.com/api/stats/watchtime")
            || normalized.contains("youtube.com/api/stats/playback")
            || normalized.contains("youtubei/v1/player") && normalized.contains("adformat")
            || normalized.contains("youtube.com/get_video_info") && normalized.contains("adformat")
            || matchesDynamicAdURL(normalized) {
            return true
        }
        return adURLPatterns.contains { normalized.contains($0) }
    }

    private static func matchesDynamicAdURL(_ value: String) -> Bool {
        if let dynamicAdURLRegex {
            return dynamicAdURLRegex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
            ) != nil
        }
        return value.range(of: #"gvt\d+\.com/ads"#, options: .regularExpression) != nil
            || value.range(of: #"yt\d?\.ggpht\.com/ad"#, options: .regularExpression) != nil
            || value.range(of: #"ytimg\.com/.*ad"#, options: .regularExpression) != nil
            || value.range(of: #"yt3\.ggpht\.com/ytc/.*ad"#, options: .regularExpression) != nil
    }
}
#else
struct YouTubeBackdropView: View {
    var info: YouTubeVideoInfo
    var playerSeconds: Double
    var playing: Bool
    var firstLyricSeconds: Double
    var offsetSeconds: Double
    var hasCaptionStartTime: Bool
    var captionStartTimeSeconds: Double
    var autoMatchedUnknownCaptionStart: Bool
    var brightness: Int
    var blur: Int
    var videoScale: Int

    var body: some View {
        EmptyView()
    }
}
#endif
