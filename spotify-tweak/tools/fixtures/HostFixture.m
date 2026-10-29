#import "HostUIKitFixture.h"
#import "SpotifyHost.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

static NSUInteger checks;
#define CHECK(condition, message) do { checks++; if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); exit(1); } } while (0)

@implementation UIView {
    NSMutableArray<UIView *> *_children;
}
- (instancetype)init { if ((self = [super init])) _children = [NSMutableArray new]; return self; }
- (NSArray<UIView *> *)subviews { return [_children copy]; }
- (void)addSubview:(UIView *)view { [_children addObject:view]; }
- (void)removeSubview:(UIView *)view { [_children removeObject:view]; }
- (void)layoutSubviews { self.layoutCalls++; }
@end
@implementation UIViewController
- (void)viewWillAppear:(BOOL)animated { self.appearanceCalls++; }
@end

@interface SPTPlayerTrack : NSObject
@property(nonatomic, strong) NSURL *URI;
@property(nonatomic, copy) NSString *trackTitle;
@property(nonatomic, copy) NSString *artistName;
@property(nonatomic, copy) NSString *albumTitle;
@property(nonatomic, copy) NSDictionary *metadata;
@end
@implementation SPTPlayerTrack @end
@interface SPTPlayerState : NSObject
@property(nonatomic, strong) SPTPlayerTrack *track;
@property(nonatomic) double position;
@property(nonatomic) double positionAsOfTimestamp;
@property(nonatomic) double duration;
@property(nonatomic) double playbackSpeed;
@property(nonatomic, getter=isPaused) BOOL paused;
@property(nonatomic, getter=isPlaying) BOOL playing;
@property(nonatomic, getter=isLoading) BOOL loading;
@end
@implementation SPTPlayerState @end

static NSUInteger stateCalls, observerCalls, callbackCalls, seekCalls, uiInitializations;
static double lastSeek;
static id seekReturn;
static BOOL throwSeek;
@interface FixturePlayerBase : NSObject
@property(nonatomic, strong) SPTPlayerState *fixtureState;
- (SPTPlayerState *)state;
- (void)addPlayerObserver:(id)observer;
- (void)removePlayerObserver:(id)observer;
- (id)seekTo:(double)position;
@end
@implementation FixturePlayerBase
- (SPTPlayerState *)state { stateCalls++; return self.fixtureState; }
- (void)addPlayerObserver:(id)observer { observerCalls++; }
- (void)removePlayerObserver:(id)observer {}
- (id)seekTo:(double)position {
    seekCalls++; lastSeek = position;
    if (throwSeek) [NSException raise:@"FixtureSeekUnavailable" format:@"Synthetic failure"];
    return seekReturn;
}
@end

static void (*seekHandler)(int64_t);
void IVLyricsSpotifyUISetSeekHandler(void (*handler)(int64_t)) { seekHandler = handler; }
@interface IVLyricsSpotifyUI : NSObject
@property(nonatomic) BOOL hasTrackAndLyrics;
@property(nonatomic, copy) void (^onReadyChanged)(BOOL);
@property(nonatomic, strong) NSDictionary *lastState;
@property(nonatomic) NSUInteger updates;
@property(nonatomic) NSUInteger disconnects;
+ (instancetype)shared;
- (void)updateStateJSON:(NSString *)json;
- (void)attachCardToView:(UIView *)view;
- (void)attachFullscreenToView:(UIView *)view;
- (void)detachFromView:(UIView *)view;
- (void)hostDisconnected;
- (void)presentFromViewController:(UIViewController *)controller;
@end
@implementation IVLyricsSpotifyUI
+ (instancetype)shared { static IVLyricsSpotifyUI *ui; if (!ui) { ui = [self new]; uiInitializations++; } return ui; }
- (void)updateStateJSON:(NSString *)json {
    CHECK(NSThread.isMainThread, "state JSON reaches main thread");
    NSDictionary *state = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    CHECK(state != nil, "JSON is valid");
    if (![self.lastState[@"spotifyID"] isEqual:state[@"spotifyID"]]) self.hasTrackAndLyrics = NO;
    self.lastState = state; self.updates++;
}
- (void)attach:(UIView *)view name:(NSString *)name {
    for (UIView *child in view.subviews) if ([child.accessibilityIdentifier isEqual:name]) return;
    UIView *own = [UIView new]; own.accessibilityIdentifier = name; [view addSubview:own];
}
- (void)attachCardToView:(UIView *)view { [self attach:view name:@"ivlyrics.spotify.card"]; }
- (void)attachFullscreenToView:(UIView *)view { [self attach:view name:@"ivlyrics.spotify.fullscreen"]; }
- (void)detachFromView:(UIView *)view {
    for (UIView *child in view.subviews) if ([child.accessibilityIdentifier hasPrefix:@"ivlyrics.spotify."]) [view removeSubview:child];
}
- (void)hostDisconnected { self.disconnects++; self.hasTrackAndLyrics = NO; self.lastState = nil; }
- (void)presentFromViewController:(UIViewController *)controller {}
@end

static NSMutableDictionary *bundleInfo;
NSDictionary *IVLHostTestBundleInfo(void) { return bundleInfo; }
static void OriginalChanged(id self, SEL command, id player, id state) { callbackCalls++; }
static void OriginalLayout(id self, SEL command) { ((UIView *)self).layoutCalls++; }
static Class Register(const char *name, Class parent) {
    Class cls = objc_allocateClassPair(parent, name, 0); CHECK(cls != Nil, "fixture class allocation"); return cls;
}
static void Changed(id player, id state) {
    id observer = [NSClassFromString(@"_TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation") new];
    ((void (*)(id,SEL,id,id))objc_msgSend)(observer, NSSelectorFromString(@"player:stateDidChange:"), player, state);
}
static void Ready(BOOL value) {
    IVLyricsSpotifyUI *ui = [IVLyricsSpotifyUI shared]; ui.hasTrackAndLyrics = value;
    if (ui.onReadyChanged) ui.onReadyChanged(value);
}
static SPTPlayerState *State(void) {
    SPTPlayerTrack *track = [SPTPlayerTrack new];
    track.URI = [NSURL URLWithString:@"spotify:track:5RCOXpwf6rpZi6HGRACY3S"];
    track.trackTitle = @" Song "; track.artistName = @" Artist "; track.albumTitle = @"Album";
    track.metadata = @{@"isrc": @"FR96X2230645", @"access_token": @"must-never-cross", @"account": @"private"};
    SPTPlayerState *state = [SPTPlayerState new]; state.track = track;
    state.position = 12.345; state.positionAsOfTimestamp = 8.5; state.duration = 200.25;
    state.playbackSpeed = 1.25; state.playing = YES;
    return state;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *mode = argc > 1 ? @(argv[1]) : @"valid";
        bundleInfo = [@{@"CFBundleIdentifier": @"com.spotify.client.resigned", @"CFBundleExecutable": @"Spotify",
                        @"CFBundleShortVersionString": @"9.1.60", @"CFBundleVersion": @"916001969"} mutableCopy];
        if ([mode isEqual:@"version"]) bundleInfo[@"CFBundleShortVersionString"] = @"9.1.78";
        if ([mode isEqual:@"build"]) bundleInfo[@"CFBundleVersion"] = @"1";
        if ([mode isEqual:@"executable"]) bundleInfo[@"CFBundleExecutable"] = @"Other";
        Class playerClass = Register("SPTEsperantoPlayer", FixturePlayerBase.class);
        if ([mode isEqual:@"seek_abi"]) class_addMethod(playerClass, @selector(seekTo:), (IMP)OriginalLayout, "v24@0:8d16");
        objc_registerClassPair(playerClass);
        Class observer = Register("_TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation", NSObject.class);
        class_addMethod(observer, NSSelectorFromString(@"player:stateDidChange:"), (IMP)OriginalChanged, "v32@0:8@16@24"); objc_registerClassPair(observer);
        Class cardClass = Nil;
        if (![mode isEqual:@"missing"]) {
            cardClass = Register("_TtC22Lyrics_CardElementImpl8CardView", UIView.class);
            if ([mode isEqual:@"layout_abi"]) class_addMethod(cardClass, @selector(layoutSubviews), (IMP)OriginalLayout, "@16@0:8");
            objc_registerClassPair(cardClass);
        }
        Class fullscreenClass = Register("_TtC32Lyrics_FullscreenElementPageImpl14FullscreenView", UIView.class); objc_registerClassPair(fullscreenClass);
        Class lyricsClass = Nil;
        if (![mode isEqual:@"lyrics_missing"]) {
            lyricsClass = Register("_TtC32Lyrics_FullscreenElementPageImpl10LyricsView", [mode isEqual:@"lyrics_superclass"] ? NSObject.class : UIView.class);
            objc_registerClassPair(lyricsClass);
        }
        Class controllerClass = Register("_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController", UIViewController.class); objc_registerClassPair(controllerClass);
        IMP priorState = class_getMethodImplementation(playerClass, @selector(state));
        IMP priorCallback = class_getMethodImplementation(observer, NSSelectorFromString(@"player:stateDidChange:"));
        BOOL supported = [mode isEqual:@"valid"];
        __block BOOL installed;
        if ([mode isEqual:@"thread"]) {
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                installed = IVLyricsSpotifyInstallHostHooks(); dispatch_semaphore_signal(done);
            });
            CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, "background install returns promptly");
        } else installed = IVLyricsSpotifyInstallHostHooks();
        CHECK(installed == supported, "strict activation gate");
        CHECK(IVLyricsSpotifyHostIsAvailable() == supported, "availability matches install");
        if (!supported) {
            CHECK(class_getMethodImplementation(playerClass, @selector(state)) == priorState, "unsupported leaves getter unchanged");
            CHECK(class_getMethodImplementation(observer, NSSelectorFromString(@"player:stateDidChange:")) == priorCallback, "unsupported leaves callback unchanged");
            CHECK(uiInitializations == 0, "unsupported does not initialize UI");
            CHECK(seekHandler == NULL, "unsupported does not expose seek");
            printf("%s: %lu assertions passed\n", mode.UTF8String, (unsigned long)checks); return 0;
        }
        CHECK(IVLyricsSpotifyInstallHostHooks(), "install is idempotent");
        CHECK(class_getMethodImplementation(FixturePlayerBase.class, @selector(state)) == priorState, "inherited getter is not modified on base class");
        CHECK(class_getMethodImplementation(UIView.class, @selector(layoutSubviews)) != class_getMethodImplementation(cardClass, @selector(layoutSubviews)), "view hook stays on subclass");
        FixturePlayerBase *player = [playerClass new]; SPTPlayerState *state = State(); player.fixtureState = state;
        IVLyricsSpotifyUI *ui = [IVLyricsSpotifyUI shared];
        CHECK([player state] == state, "getter original result preserved");
        CHECK(stateCalls == 1, "getter original called once");
        CHECK([ui.lastState[@"title"] isEqual:@"Song"] && [ui.lastState[@"artist"] isEqual:@"Artist"], "text normalization");
        CHECK([ui.lastState[@"spotifyID"] isEqual:@"5RCOXpwf6rpZi6HGRACY3S"], "track ID decoded");
        CHECK([ui.lastState[@"durationMs"] longLongValue] == 200250, "duration seconds to milliseconds");
        CHECK([ui.lastState[@"positionMs"] longLongValue] == 12345, "running position milliseconds");
        CHECK([ui.lastState[@"isrc"] isEqual:@"FR96X2230645"], "ISRC preserved");
        CHECK(ui.lastState.count == 9 && ui.lastState[@"access_token"] == nil && ui.lastState[@"account"] == nil, "metadata allowlist excludes private keys");
        CHECK([ui.lastState[@"playing"] boolValue] && [ui.lastState[@"speed"] doubleValue] == 1.25, "playback state preserved");
        [player addPlayerObserver:[NSObject new]];
        CHECK(observerCalls == 1 && stateCalls == 2, "observer original then original getter once");
        Changed(player, state); CHECK(callbackCalls == 1, "callback original called once");
        state.paused = YES; Changed(player, state);
        CHECK([ui.lastState[@"positionMs"] longLongValue] == 8500 && ![ui.lastState[@"playing"] boolValue], "paused position uses snapshot");
        state.paused = NO; state.loading = YES; Changed(player, state);
        CHECK(![ui.lastState[@"playing"] boolValue], "loading does not extrapolate");
        state.loading = NO;
        seekReturn = [NSObject new]; seekHandler(12500);
        CHECK(seekCalls == 1 && lastSeek == 12.5, "seek milliseconds to object-returning seconds method");
        seekHandler(INT64_MAX); CHECK(seekCalls == 2 && lastSeek == 200.25, "seek clamped to duration");
        seekHandler(-1); CHECK(seekCalls == 2, "negative seek rejected");
        id wrapper = [NSObject new]; Changed(wrapper, state); seekHandler(1000);
        CHECK(seekCalls == 3 && lastSeek == 1, "same-track wrapper preserves known weak Esperanto target");
        state.track.URI = [NSURL URLWithString:@"spotify:track:4RCOXpwf6rpZi6HGRACY3S"]; Changed(wrapper, state); seekHandler(1000);
        CHECK(seekCalls == 3, "different-track wrapper cannot seek old target");
        state.track.URI = [NSURL URLWithString:@"spotify:track:5RCOXpwf6rpZi6HGRACY3S"]; Changed(player, state);
        throwSeek = YES; seekHandler(1000);
        CHECK(seekCalls == 4, "seek exception contained");
        seekHandler(1000); CHECK(seekCalls == 4, "failed seek target cleared");
        throwSeek = NO; Changed(player, state);
        UIView *card = [cardClass new], *full = [fullscreenClass new];
        UIView *visible = [UIView new], *hidden = [UIView new]; hidden.hidden = YES;
        [card addSubview:visible]; [card addSubview:hidden]; [card layoutSubviews];
        CHECK(card.layoutCalls == 1 && card.subviews.count == 3, "card original plus own child");
        CHECK(!visible.hidden && hidden.hidden, "native untouched while not ready");
        Ready(YES);
        CHECK(visible.hidden && hidden.hidden && !card.subviews.lastObject.hidden, "ready hides native only");
        [card layoutSubviews]; CHECK(card.layoutCalls == 2 && card.subviews.count == 3, "repeated attach does not duplicate child or original call");
        UIView *late = [UIView new]; [card addSubview:late]; [card layoutSubviews]; CHECK(late.hidden, "new native child hidden after original layout");
        Ready(NO); CHECK(!visible.hidden && hidden.hidden && !late.hidden, "exact hidden-state restoration");
        UIView *fullNative = [UIView new], *lyricsRegion = [lyricsClass new]; [lyricsRegion addSubview:fullNative];
        UIView *header = [UIView new], *controls = [UIView new], *footer = [UIView new], *progress = [UIView new]; progress.hidden = YES;
        [full addSubview:header]; [full addSubview:lyricsRegion]; [full addSubview:controls]; [full addSubview:footer]; [full addSubview:progress];
        [full layoutSubviews]; Ready(YES);
        CHECK(fullNative.hidden && full.layoutCalls == 1 && lyricsRegion.subviews.count == 2, "fullscreen original plus bounded lyrics-region replacement");
        CHECK(!header.hidden && !controls.hidden && !footer.hidden && progress.hidden && !lyricsRegion.hidden && full.subviews.count == 5, "native header controls footer remain untouched");
        UIView *duplicateRegion = [lyricsClass new]; [full addSubview:duplicateRegion]; [full layoutSubviews];
        CHECK(!fullNative.hidden && lyricsRegion.subviews.count == 1 && duplicateRegion.subviews.count == 0, "duplicate lyrics regions restore native and detach overlay");
        CHECK(!header.hidden && !controls.hidden, "ambiguous fallback preserves navigation and playback controls");
        [full removeSubview:duplicateRegion]; [full layoutSubviews]; CHECK(fullNative.hidden && lyricsRegion.subviews.count == 2, "unique region can be reattached");
        [full removeSubview:lyricsRegion]; [full layoutSubviews];
        CHECK(!fullNative.hidden && lyricsRegion.subviews.count == 1 && !header.hidden && !controls.hidden, "missing region restores old native state and detaches overlay");
        [full addSubview:lyricsRegion]; [full layoutSubviews];
        UIView *ownedTree = [UIView new]; ownedTree.accessibilityIdentifier = @"ivlyrics.spotify.fixture";
        UIView *ownedCandidate = [lyricsClass new]; [ownedTree addSubview:ownedCandidate]; [full addSubview:ownedTree]; [full layoutSubviews];
        CHECK(fullNative.hidden && ownedCandidate.subviews.count == 0 && !ownedTree.hidden, "owned descendants excluded from region discovery");
        [full removeSubview:ownedTree];
        UIView *deepTree = [UIView new], *cursor = deepTree; [full addSubview:deepTree];
        for (NSUInteger index = 0; index < 9; index++) { UIView *child = [UIView new]; [cursor addSubview:child]; cursor = child; }
        [full layoutSubviews]; CHECK(!fullNative.hidden && lyricsRegion.subviews.count == 1, "depth truncation fails safely even with one visible candidate");
        [full removeSubview:deepTree];
        UIView *wideTree = [UIView new]; for (NSUInteger index = 0; index < 300; index++) [wideTree addSubview:[UIView new]];
        [full addSubview:wideTree]; [full layoutSubviews]; CHECK(!fullNative.hidden && lyricsRegion.subviews.count == 1, "node budget fails safely");
        [full removeSubview:wideTree]; [full layoutSubviews]; CHECK(fullNative.hidden && !header.hidden && !controls.hidden && !footer.hidden, "safe subtree recovery never hides controls");
        state.track.URI = [NSURL URLWithString:@"spotify:episode:5RCOXpwf6rpZi6HGRACY3S"]; Changed(player, state);
        CHECK(ui.disconnects == 1 && !fullNative.hidden && !visible.hidden && hidden.hidden, "non-song disconnect restores all containers");
        NSUInteger previousSeeks = seekCalls; seekHandler(1000); CHECK(seekCalls == previousSeeks, "disconnected seek rejected");
        state = State(); player.fixtureState = state; Changed(player, state);
        state.duration = NAN; state.position = INFINITY; state.playbackSpeed = NAN; Changed(player, state);
        CHECK([ui.lastState[@"durationMs"] longLongValue] == 0 && [ui.lastState[@"positionMs"] longLongValue] == 0 && [ui.lastState[@"speed"] doubleValue] == 1, "non-finite host values sanitized");
        state.playbackSpeed = 12; Changed(player, state); CHECK([ui.lastState[@"speed"] doubleValue] == 1, "speed obeys UI maximum of eight");
        state = State(); player.fixtureState = state;
        __weak id weakPlayer = player; Changed(player, state); player = nil;
        CHECK(weakPlayer == nil, "adapter does not retain host player");
        previousSeeks = seekCalls; seekHandler(1000); CHECK(seekCalls == previousSeeks, "released player cannot seek");
        UIViewController *controller = [controllerClass new]; [controller viewWillAppear:YES]; CHECK(controller.appearanceCalls == 1, "appearance original preserved");
        FixturePlayerBase *backgroundPlayer = [playerClass new]; backgroundPlayer.fixtureState = State();
        __block BOOL workerFinished = NO;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            Changed(backgroundPlayer, backgroundPlayer.fixtureState);
            dispatch_async(dispatch_get_main_queue(), ^{ workerFinished = YES; });
        });
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (!workerFinished && deadline.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        CHECK(workerFinished && ui.lastState != nil, "background callback delivered on main");
        printf("valid: %lu assertions passed\n", (unsigned long)checks);
    }
    return 0;
}
