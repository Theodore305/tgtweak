// TelegramCallTweak — rewritten source.
// Behaviour reconstructed from the compiled TelegramCallTweak.dylib (original by oceanondawave):
//   * "Call Tweak Settings" row above the tab bar while Telegram's Settings screen is visible
//     (fallback: small floating 🎧 button if that screen can't be hooked)
//   * Force built-in mic (keeps Bluetooth/headphones for output only)
//   * Share Audio Only (drops screen-share video frames, keeps the audio)
//   * Screen media volume / microphone volume (0-300%, applied to the samples AudioUnitRender returns)
//
// Everything is resolved at runtime (class lookup by name, hooks installed with retries),
// so a renamed Swift module prefix or a late-loaded image no longer breaks the tweak.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <sys/mman.h>
#import <string.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <atomic>
#import <math.h>

#define LOG(fmt, ...) NSLog(@"[TelegramCallTweak] " fmt, ##__VA_ARGS__)

static void ShowToastFor(NSString *text, double seconds);

static NSString *const kForceMic  = @"tweak_forceBuiltInMic";
static NSString *const kAudioOnly = @"tweak_shareAudioOnly";
static NSString *const kMicVol    = @"tweak_micVolume";
static NSString *const kMediaVol  = @"tweak_mediaVolume";

// AVAudioSessionCategoryOptionAllowBluetooth (renamed ...HFP in iOS 26, same value)
static const NSUInteger kAllowBluetoothHFP = 0x4;

#pragma mark - Preferences (shared app-group container, so the broadcast extension can read them too)

static std::atomic<bool>  gForceMic{false};
static std::atomic<bool>  gAudioOnly{false};
static std::atomic<float> gMicVol{100.f};
static std::atomic<float> gMediaVol{100.f};
static NSMutableDictionary *gPrefs;

static NSString *PrefsPath(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSURL *c = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:
                [NSString stringWithFormat:@"group.%@", bid]];
    NSString *base = c.path;
    if (!base) base = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [base stringByAppendingPathComponent:@"telegram-data"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"tweak_preferences.plist"];
}

static void LoadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:PrefsPath()];
    gPrefs = d ? [d mutableCopy] : [NSMutableDictionary new];
    gForceMic  = gPrefs[kForceMic] ? [gPrefs[kForceMic] boolValue] : YES;   // on by default
    gAudioOnly = [gPrefs[kAudioOnly] boolValue];
    gMicVol    = gPrefs[kMicVol]   ? [gPrefs[kMicVol] floatValue]   : 100.f;
    gMediaVol  = gPrefs[kMediaVol] ? [gPrefs[kMediaVol] floatValue] : 100.f;
}

static void SavePref(NSString *key, id value) {
    @try {
        @synchronized (gPrefs) {
            gPrefs[key] = value;
            [gPrefs writeToFile:PrefsPath() atomically:YES];
        }
    } @catch (NSException *e) {
        LOG(@"Exception saving setting: %@", e.reason);
    }
}

#pragma mark - Audio session (force built-in mic, mic gain)

static void ApplyBuiltInMic(void) {
    if (!gForceMic) return;
    AVAudioSession *s = AVAudioSession.sharedInstance;
    for (AVAudioSessionPortDescription *p in s.currentRoute.inputs)
        if ([p.portType isEqualToString:AVAudioSessionPortBuiltInMic]) return;   // already built-in
    for (AVAudioSessionPortDescription *p in s.availableInputs) {
        if ([p.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
            NSError *err = nil;
            [s setPreferredInput:p error:&err];
            if (err) LOG(@"setPreferredInput failed: %@", err);
            break;
        }
    }
}

static NSString *RouteDescription(void) {
    AVAudioSessionRouteDescription *r = AVAudioSession.sharedInstance.currentRoute;
    AVAudioSessionPortDescription *in = r.inputs.firstObject, *out = r.outputs.firstObject;
    return [NSString stringWithFormat:@"Микрофон: %@ (%@)\nЗвук: %@ (%@)",
            in.portName ?: @"—", in.portType ?: @"—", out.portName ?: @"—", out.portType ?: @"—"];
}

static NSInteger gRouteSeq = 0;

@interface TweakAudioObserver : NSObject
+ (instancetype)sharedInstance;
- (void)audioRouteChanged:(NSNotification *)n;
@end
@implementation TweakAudioObserver
+ (instancetype)sharedInstance {
    static TweakAudioObserver *o; static dispatch_once_t t;
    dispatch_once(&t, ^{ o = [TweakAudioObserver new]; });
    return o;
}
- (void)audioRouteChanged:(NSNotification *)n {
    dispatch_async(dispatch_get_main_queue(), ^{
        ApplyBuiltInMic();
        // Diagnostic toast while a call/recording session is active: shows where mic and sound really go.
        NSInteger seq = ++gRouteSeq;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (seq != gRouteSeq) return;
            if (![AVAudioSession.sharedInstance.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) return;
            ShowToastFor(RouteDescription(), 5);
        });
    });
}
@end

// With "force built-in mic": drop Bluetooth HFP (that's the headset's mic + mono call quality) and
// allow A2DP so the headphones stay as the output.
static AVAudioSessionCategoryOptions AdjustOptions(NSString *cat, AVAudioSessionCategoryOptions o) {
    if (gForceMic && [cat isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        o &= ~kAllowBluetoothHFP;
        o |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
    }
    return o;
}

static void AfterCategoryChange(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ ApplyBuiltInMic(); });
}

static AVAudioSessionCategoryOptions (*orig_categoryOptions)(id, SEL);
static AVAudioSessionCategoryOptions hook_categoryOptions(id self, SEL _cmd) {
    AVAudioSessionCategoryOptions o = orig_categoryOptions(self, _cmd);
    if (gForceMic) o &= ~kAllowBluetoothHFP;
    return o;
}

// Telegram's audio session code and WebRTC use different variants of setCategory, so cover all three.
static BOOL (*orig_setCategory)(id, SEL, NSString *, NSString *, AVAudioSessionCategoryOptions, NSError **);
static BOOL hook_setCategory(id self, SEL _cmd, NSString *cat, NSString *mode,
                             AVAudioSessionCategoryOptions opts, NSError **err) {
    BOOL r = orig_setCategory(self, _cmd, cat, mode, AdjustOptions(cat, opts), err);
    if (r) AfterCategoryChange();
    return r;
}

static BOOL (*orig_setCategoryWithOptions)(id, SEL, NSString *, AVAudioSessionCategoryOptions, NSError **);
static BOOL hook_setCategoryWithOptions(id self, SEL _cmd, NSString *cat, AVAudioSessionCategoryOptions opts, NSError **err) {
    BOOL r = orig_setCategoryWithOptions(self, _cmd, cat, AdjustOptions(cat, opts), err);
    if (r) AfterCategoryChange();
    return r;
}

static BOOL (*orig_setCategoryRSP)(id, SEL, NSString *, NSString *, NSUInteger, AVAudioSessionCategoryOptions, NSError **);
static BOOL hook_setCategoryRSP(id self, SEL _cmd, NSString *cat, NSString *mode, NSUInteger policy,
                                AVAudioSessionCategoryOptions opts, NSError **err) {
    BOOL r = orig_setCategoryRSP(self, _cmd, cat, mode, policy, AdjustOptions(cat, opts), err);
    if (r) AfterCategoryChange();
    return r;
}

#pragma mark - WebRTC hooks

// Screen-share audio: 16-bit PCM, scaled in place on a copy.
static void (*orig_addExternalAudioData)(id, SEL, NSData *);
static void hook_addExternalAudioData(id self, SEL _cmd, NSData *data) {
    float v = gMediaVol.load();
    if (data.length < 2 || fabsf(v - 100.f) < 0.5f) { orig_addExternalAudioData(self, _cmd, data); return; }
    NSMutableData *m = [data mutableCopy];
    int16_t *p = (int16_t *)m.mutableBytes;
    NSUInteger n = m.length / sizeof(int16_t);
    float g = v / 100.f;
    for (NSUInteger i = 0; i < n; i++) {
        long x = lrintf((float)p[i] * g);
        p[i] = (int16_t)(x > INT16_MAX ? INT16_MAX : (x < INT16_MIN ? INT16_MIN : x));
    }
    orig_addExternalAudioData(self, _cmd, m);
}

// Audio-only sharing: swallow video frames but still fire the completion so the capturer doesn't stall.
static void (*orig_submitSampleBuffer)(id, SEL, CMSampleBufferRef, NSInteger, id);
static void hook_submitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb, NSInteger rotation, id completion) {
    if (gAudioOnly) {
        if (completion) ((void (^)(void))completion)();
        return;
    }
    orig_submitSampleBuffer(self, _cmd, sb, rotation, completion);
}

#pragma mark - Settings UI

static BOOL gHookAudio = NO, gHookVideo = NO, gHookSession = NO, gHookSettings = NO, gHookMic = NO;
static BOOL gMicRebindEnabled = NO;                // mic hook is installed only when mic volume != 100%
static void EnableMicHook(void);
static BOOL gRowWanted = NO;                       // a profile/settings screen is on screen
static NSHashTable *gVisibleProfiles;              // weak: visible PeerInfoScreenImpl instances
static void RefreshSettingsRow(void);

static NSString *HookStatus(void) {
    return [NSString stringWithFormat:@"Hooks: звук экрана %@ · видео %@ · аудиосессия %@ · экран настроек %@ · усиление микрофона %@",
            gHookAudio ? @"✓" : @"✗", gHookVideo ? @"✓" : @"✗", gHookSession ? @"✓" : @"✗", gHookSettings ? @"✓" : @"✗", gMicRebindEnabled ? (gHookMic ? @"✓" : @"✗") : @"выкл (100%)"];
}

@interface TweakSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *micLabel, *mediaLabel;
@property (nonatomic, strong) UISlider *micSlider, *mediaSlider;
@property (nonatomic, strong) UISwitch *forceMicSwitch, *audioOnlySwitch;
@end

@implementation TweakSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Call Tweak Settings";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(dismissSelf)];
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
}

- (void)dismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? 2 : 3; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return s == 0 ? @"Preferences" : @"Volume Levels"; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s { return s == 1 ? HookStatus() : nil; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return (ip.section == 1 && ip.row < 2) ? 68 : 48; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if (ip.section == 0) {
        UISwitch *sw = [UISwitch new];
        if (ip.row == 0) {
            c.textLabel.text = @"Force Built-in Mic";
            [sw setOn:gForceMic animated:NO];
            [sw addTarget:self action:@selector(forceMicToggled:) forControlEvents:UIControlEventValueChanged];
            self.forceMicSwitch = sw;
        } else {
            c.textLabel.text = @"Share Audio Only";
            [sw setOn:gAudioOnly animated:NO];
            [sw addTarget:self action:@selector(audioOnlyToggled:) forControlEvents:UIControlEventValueChanged];
            self.audioOnlySwitch = sw;
        }
        c.accessoryView = sw;
        return c;
    }
    if (ip.row < 2) {
        BOOL mic = (ip.row == 0);
        UILabel *l = [UILabel new];
        l.font = [UIFont systemFontOfSize:15];
        l.translatesAutoresizingMaskIntoConstraints = NO;
        UISlider *s = [UISlider new];
        s.minimumValue = 0;
        s.maximumValue = mic ? 300 : 200;
        s.translatesAutoresizingMaskIntoConstraints = NO;
        float v = mic ? gMicVol.load() : gMediaVol.load();
        [s setValue:v animated:NO];
        l.text = [NSString stringWithFormat:mic ? @"Microphone Voice Volume (%.0f%%)" : @"Screen Media Volume (%.0f%%)", v];
        [s addTarget:self action:(mic ? @selector(micSliderChanged:) : @selector(mediaSliderChanged:))
            forControlEvents:UIControlEventValueChanged];
        if (mic) { self.micLabel = l; self.micSlider = s; } else { self.mediaLabel = l; self.mediaSlider = s; }
        [c.contentView addSubview:l];
        [c.contentView addSubview:s];
        UILayoutGuide *g = c.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [l.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:8],
            [l.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [l.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
            [s.topAnchor constraintEqualToAnchor:l.bottomAnchor constant:6],
            [s.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
            [s.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        ]];
        return c;
    }
    c.textLabel.text = @"Reset Volumes to 100%";
    c.textLabel.textColor = UIColor.systemBlueColor;
    c.selectionStyle = UITableViewCellSelectionStyleDefault;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1 && ip.row == 2) {
        gMicVol = 100.f; gMediaVol = 100.f;
        SavePref(kMicVol, @100.0f); SavePref(kMediaVol, @100.0f);
        [self.micSlider setValue:100 animated:YES];
        [self.mediaSlider setValue:100 animated:YES];
        self.micLabel.text = @"Microphone Voice Volume (100%)";
        self.mediaLabel.text = @"Screen Media Volume (100%)";
    }
}

- (void)forceMicToggled:(UISwitch *)sw {
    gForceMic = sw.isOn;
    SavePref(kForceMic, @(sw.isOn));
    ApplyBuiltInMic();
}
- (void)audioOnlyToggled:(UISwitch *)sw {
    gAudioOnly = sw.isOn;
    SavePref(kAudioOnly, @(sw.isOn));
}
- (void)micSliderChanged:(UISlider *)s {
    float v = roundf(s.value);
    gMicVol = v; SavePref(kMicVol, @(v));
    if (fabsf(v - 100.f) >= 0.5f) EnableMicHook();
    self.micLabel.text = [NSString stringWithFormat:@"Microphone Voice Volume (%.0f%%)", v];
}
- (void)mediaSliderChanged:(UISlider *)s {
    float v = roundf(s.value);
    gMediaVol = v; SavePref(kMediaVol, @(v));
    self.mediaLabel.text = [NSString stringWithFormat:@"Screen Media Volume (%.0f%%)", v];
}
@end

#pragma mark - Own overlay window (independent of Telegram's window / touch handling)

static void ShowToast(NSString *text);

// Passes every touch that doesn't hit one of our views through to Telegram underneath.
@interface TweakPassthroughWindow : UIWindow
@end
@implementation TweakPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

@interface TweakHostViewController : UIViewController
@end
@implementation TweakHostViewController
- (void)loadView {
    UIView *v = [UIView new];
    v.backgroundColor = UIColor.clearColor;
    self.view = v;
}
@end

static TweakPassthroughWindow *gTweakWindow;
static TweakHostViewController *gHostVC;

static UIWindowScene *ActiveScene(void) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class] && sc.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)sc;
    return nil;
}

static void EnsureTweakWindow(void) {
    UIWindowScene *sc = ActiveScene();
    if (!sc) return;
    if (gTweakWindow && gTweakWindow.windowScene != sc) {
        gTweakWindow.hidden = YES;
        gTweakWindow = nil;
        gHostVC = nil;
    }
    if (gTweakWindow) { gTweakWindow.hidden = NO; return; }
    gTweakWindow = [[TweakPassthroughWindow alloc] initWithWindowScene:sc];
    gTweakWindow.windowLevel = UIWindowLevelAlert + 100;
    gTweakWindow.backgroundColor = UIColor.clearColor;
    gHostVC = [TweakHostViewController new];
    gTweakWindow.rootViewController = gHostVC;
    gTweakWindow.hidden = NO;
}

@interface TweakActions : NSObject
+ (void)openCallTweakSettingsModally;
@end
@implementation TweakActions
+ (void)openCallTweakSettingsModally {
    EnsureTweakWindow();
    if (!gHostVC) { ShowToast(@"Окно твика недоступно, попробуйте ещё раз"); return; }
    if (gHostVC.presentedViewController) return;
    TweakSettingsViewController *vc = [TweakSettingsViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [gHostVC presentViewController:nav animated:YES completion:nil];
}
@end

#pragma mark - Floating button + load toast (independent of Telegram's own screens)

static BOOL gFloatHidden = NO;

// Row sizing (pinned above the tab bar). Tweak these if it overlaps something.
#define ROW_HEIGHT      50.0
#define ROW_SIDE_MARGIN 16.0
#define ROW_BOTTOM_GAP  (49.0 + 12.0)     // tab bar + margin

@interface TweakFloat : NSObject
+ (instancetype)shared;
- (void)ensure;
@end
@implementation TweakFloat {
    UIButton *_row;      // list-style row, shown only while Telegram's Settings screen is visible
    UIButton *_btn;      // fallback floating button, used only when the Settings hook isn't installed
}
+ (instancetype)shared {
    static TweakFloat *f; static dispatch_once_t t;
    dispatch_once(&t, ^{ f = [TweakFloat new]; });
    return f;
}
- (void)buildRow {
    _row = [UIButton buttonWithType:UIButtonTypeCustom];
    _row.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    _row.layer.cornerRadius = 12;
    _row.layer.borderWidth = 0.5;
    _row.layer.borderColor = UIColor.separatorColor.CGColor;
    [_row setTitle:@"🎧  Call Tweak Settings" forState:UIControlStateNormal];
    [_row setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
    _row.titleLabel.font = [UIFont systemFontOfSize:17];
    _row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    _row.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 40);
    UIImageView *chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chev.tintColor = UIColor.tertiaryLabelColor;
    chev.contentMode = UIViewContentModeScaleAspectFit;
    chev.tag = 0x7042;
    chev.userInteractionEnabled = NO;
    [_row addSubview:chev];
    [_row addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
}
- (void)buildFloat {
    CGRect wb = gTweakWindow.bounds;
    _btn = [UIButton buttonWithType:UIButtonTypeCustom];
    _btn.frame = CGRectMake(wb.size.width - 60, gTweakWindow.safeAreaInsets.top + 110, 48, 48);
    _btn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.85];
    _btn.layer.cornerRadius = 24;
    [_btn setTitle:@"🎧" forState:UIControlStateNormal];
    _btn.titleLabel.font = [UIFont systemFontOfSize:24];
    [_btn addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
    [_btn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hide:)];
    lp.minimumPressDuration = 1.5;
    [_btn addGestureRecognizer:lp];
}
- (void)ensure {
    EnsureTweakWindow();
    if (!gHostVC) return;
    UIView *host = gHostVC.view;
    CGRect wb = gTweakWindow.bounds;

    // 1) Settings row (preferred)
    BOOL showRow = gHookSettings && gRowWanted;
    if (!_row) [self buildRow];
    if (_row.superview != host) [host addSubview:_row];
    _row.hidden = !showRow;
    if (showRow) {
        CGFloat w = wb.size.width - 2 * ROW_SIDE_MARGIN;
        CGFloat y = wb.size.height - gTweakWindow.safeAreaInsets.bottom - ROW_BOTTOM_GAP - ROW_HEIGHT;
        _row.frame = CGRectMake(ROW_SIDE_MARGIN, y, w, ROW_HEIGHT);
        UIView *chev = [_row viewWithTag:0x7042];
        chev.frame = CGRectMake(w - 32, (ROW_HEIGHT - 18) / 2, 12, 18);
        [host bringSubviewToFront:_row];
    }

    // 2) Fallback floating button, only if we couldn't hook the Settings screen at all
    BOOL showFloat = !gHookSettings && !gFloatHidden;
    if (showFloat) {
        if (!_btn) [self buildFloat];
        if (_btn.superview != host) [host addSubview:_btn];
        [host bringSubviewToFront:_btn];
    } else if (_btn) {
        [_btn removeFromSuperview];
    }
}
- (void)tap { [TweakActions openCallTweakSettingsModally]; }
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view; CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
- (void)hide:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    gFloatHidden = YES;               // until the next app launch
    [_btn removeFromSuperview];
}
@end

static void RefreshSettingsRow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gRowWanted = gVisibleProfiles.count > 0;
        [[TweakFloat shared] ensure];
    });
}

static void ShowToastFor(NSString *text, double seconds) {
    EnsureTweakWindow();
    UIView *host = gHostVC.view;
    if (!host) return;
    [[host viewWithTag:0x7041] removeFromSuperview];       // only one toast at a time
    UILabel *l = [UILabel new];
    l.tag = 0x7041;
    l.numberOfLines = 0;
    l.text = text;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    l.textColor = UIColor.whiteColor;
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.82];
    l.layer.cornerRadius = 10;
    l.clipsToBounds = YES;
    CGFloat maxW = gTweakWindow.bounds.size.width - 40;
    CGSize sz = [l sizeThatFits:CGSizeMake(maxW - 20, CGFLOAT_MAX)];
    l.frame = CGRectMake(20, gTweakWindow.safeAreaInsets.top + 8, maxW, sz.height + 16);
    l.userInteractionEnabled = NO;
    [host addSubview:l];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ l.alpha = 0; } completion:^(BOOL f) { [l removeFromSuperview]; }];
    });
}

static void ShowToast(NSString *text) { ShowToastFor(text, 7); }

static void ScheduleToast(int tries) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!ActiveScene() && tries > 0) { ScheduleToast(tries - 1); return; }
        ShowToast([@"TelegramCallTweak загружен\n" stringByAppendingString:HookStatus()]);
    });
}

#pragma mark - Settings screen hooks (show the row while PeerInfoScreenImpl is visible)

static void (*orig_viewDidAppear)(id, SEL, BOOL);
static void hook_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    [gVisibleProfiles addObject:self];
    RefreshSettingsRow();
}
static void (*orig_viewDidDisappear)(id, SEL, BOOL);
static void hook_viewDidDisappear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidDisappear(self, _cmd, animated);
    [gVisibleProfiles removeObject:self];
    RefreshSettingsRow();
}

#pragma mark - Microphone volume (scale what AudioUnitRender returns for the input bus)

// gHookMic is declared with the other status flags above.
static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);

static std::atomic<AudioUnit> gMicUnit{NULL};        // unit whose sample format is known
static std::atomic<int>       gMicKind{0};           // 1 = int16 PCM, 2 = float32 PCM, 0 = unknown/unsupported
static std::atomic<AudioUnit> gPendingUnit{NULL};    // seen in the render callback, format not queried yet

// Runs on the main thread (timer). Never query CoreAudio from inside the render callback:
// that thread serves both microphone and speaker, and blocking it silences the whole call.
static void ResolveMicFormat(void) {
    AudioUnit u = gPendingUnit.load();
    if (!u || u == gMicUnit.load()) return;
    AudioStreamBasicDescription f; UInt32 sz = sizeof(f);
    int kind = 0;
    if (AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &f, &sz) == noErr
        && f.mFormatID == kAudioFormatLinearPCM) {
        if ((f.mFormatFlags & kAudioFormatFlagIsSignedInteger) && f.mBitsPerChannel == 16) kind = 1;
        else if ((f.mFormatFlags & kAudioFormatFlagIsFloat) && f.mBitsPerChannel == 32) kind = 2;
    }
    gMicKind.store(kind);
    gMicUnit.store(u);
}

// Real-time safe: only atomics and arithmetic.
static void ScaleMic(AudioUnit unit, AudioBufferList *io, float g) {
    if (unit != gMicUnit.load()) { gPendingUnit.store(unit); return; }   // format not known yet: pass through
    int kind = gMicKind.load();
    if (!kind) return;
    for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
        AudioBuffer *buf = &io->mBuffers[b];
        if (!buf->mData) continue;
        if (kind == 1) {
            int16_t *p = (int16_t *)buf->mData;
            UInt32 n = buf->mDataByteSize / sizeof(int16_t);
            for (UInt32 i = 0; i < n; i++) {
                long x = lrintf((float)p[i] * g);
                p[i] = (int16_t)(x > INT16_MAX ? INT16_MAX : (x < INT16_MIN ? INT16_MIN : x));
            }
        } else {
            float *p = (float *)buf->mData;
            UInt32 n = buf->mDataByteSize / sizeof(float);
            for (UInt32 i = 0; i < n; i++) p[i] = fmaxf(-1.f, fminf(1.f, p[i] * g));
        }
    }
}

static OSStatus hook_AudioUnitRender(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                                     UInt32 bus, UInt32 frames, AudioBufferList *io) {
    OSStatus st = orig_AudioUnitRender(unit, flags, ts, bus, frames, io);
    if (st == noErr && bus == 1 && io) {                       // bus 1 = microphone input
        float v = gMicVol.load();
        if (fabsf(v - 100.f) >= 0.5f) ScaleMic(unit, io, v / 100.f);
    }
    return st;
}

// Minimal symbol rebinding (same idea as fishhook): point the app images' import of AudioUnitRender at our hook.
static void RebindSection(struct section_64 *sect, intptr_t slide, struct nlist_64 *syms, char *strtab, uint32_t *indirect) {
    bool isConst = strncmp(sect->segname, "__DATA_CONST", 16) == 0;
    uint32_t *indices = indirect + sect->reserved1;
    void **bindings = (void **)((uintptr_t)slide + sect->addr);
    uintptr_t pg = (uintptr_t)getpagesize();
    uintptr_t start = (uintptr_t)bindings & ~(pg - 1);
    uintptr_t end = ((uintptr_t)bindings + sect->size + pg - 1) & ~(pg - 1);
    bool unlocked = false;
    for (uint32_t i = 0; i < sect->size / sizeof(void *); i++) {
        uint32_t si = indices[i];
        if (si == INDIRECT_SYMBOL_ABS || si == INDIRECT_SYMBOL_LOCAL || si == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        const char *name = strtab + syms[si].n_un.n_strx;
        if (!(name[0] && name[1] && strcmp(name + 1, "AudioUnitRender") == 0)) continue;
        if (bindings[i] == (void *)hook_AudioUnitRender) continue;
        if (isConst && !unlocked) {
            if (mprotect((void *)start, end - start, PROT_READ | PROT_WRITE) != 0) { LOG(@"mprotect failed"); return; }
            unlocked = true;
        }
        bindings[i] = (void *)hook_AudioUnitRender;
        gHookMic = YES;
    }
    if (unlocked) mprotect((void *)start, end - start, PROT_READ);
}

static void RebindImage(const struct mach_header *header, intptr_t slide) {
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname) return;
    if (strncmp(info.dli_fname, "/System/", 8) == 0 || strncmp(info.dli_fname, "/usr/", 5) == 0) return;   // only app images
    const struct mach_header_64 *h = (const struct mach_header_64 *)header;
    if (h->magic != MH_MAGIC_64) return;
    if (!orig_AudioUnitRender) {
        orig_AudioUnitRender = (OSStatus (*)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *))dlsym(RTLD_DEFAULT, "AudioUnitRender");
        if (!orig_AudioUnitRender) return;
    }
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    uintptr_t cur = (uintptr_t)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cur;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
        } else if (lc->cmd == LC_SYMTAB) symtab = (const struct symtab_command *)cur;
        else if (lc->cmd == LC_DYSYMTAB) dysymtab = (const struct dysymtab_command *)cur;
        cur += lc->cmdsize;
    }
    if (!linkedit || !symtab || !dysymtab || dysymtab->nindirectsyms == 0) return;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    struct nlist_64 *syms = (struct nlist_64 *)(base + symtab->symoff);
    char *strtab = (char *)(base + symtab->stroff);
    uint32_t *indirect = (uint32_t *)(base + dysymtab->indirectsymoff);
    cur = (uintptr_t)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cur;
            if (strcmp(seg->segname, SEG_DATA) == 0 || strcmp(seg->segname, "__DATA_CONST") == 0) {
                struct section_64 *sects = (struct section_64 *)(cur + sizeof(struct segment_command_64));
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    uint32_t t = sects[j].flags & SECTION_TYPE;
                    if (t == S_LAZY_SYMBOL_POINTERS || t == S_NON_LAZY_SYMBOL_POINTERS)
                        RebindSection(&sects[j], slide, syms, strtab, indirect);
                }
            }
        }
        cur += lc->cmdsize;
    }
}

static void EnableMicHook(void) {
    if (gMicRebindEnabled) return;
    gMicRebindEnabled = YES;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) RebindImage(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    LOG(@"Mic hook enabled (%@)", gHookMic ? @"rebound" : @"nothing rebound");
}

#pragma mark - Hook installation (idempotent, retried as images load)

static BOOL HookMethod(Class c, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    const char *types = method_getTypeEncoding(m);
    IMP inherited = method_getImplementation(m);
    if (class_addMethod(c, sel, imp, types)) *orig = inherited;      // method was inherited: add override
    else *orig = method_setImplementation(m, imp);                   // class owns it: replace
    return YES;
}

// Exact name first, then any runtime class whose name ends with / contains `needle` (Swift prefixes, mangling).
static Class FindClass(const char *needle) {
    Class exact = objc_getClass(needle);
    if (exact) return exact;
    unsigned n = 0;
    Class *list = objc_copyClassList(&n);
    Class found = Nil, loose = Nil;
    size_t nl = strlen(needle);
    for (unsigned i = 0; i < n; i++) {
        const char *nm = class_getName(list[i]);
        size_t l = strlen(nm);
        if (l >= nl && strcmp(nm + l - nl, needle) == 0) { found = list[i]; break; }
        if (!loose && strstr(nm, needle)) loose = list[i];
    }
    free(list);
    return found ?: loose;
}

static void TryInstall(void) {
    @synchronized ([TweakActions class]) {
        if (!gHookAudio) {
            Class c = FindClass("OngoingCallThreadLocalContextWebrtc");
            if (c && HookMethod(c, NSSelectorFromString(@"addExternalAudioData:"), (IMP)hook_addExternalAudioData, (IMP *)&orig_addExternalAudioData)) {
                gHookAudio = YES; LOG(@"Hooked %s addExternalAudioData:", class_getName(c));
            }
        }
        if (!gHookVideo) {
            Class c = FindClass("OngoingCallThreadLocalContextVideoCapturer");
            if (c && HookMethod(c, NSSelectorFromString(@"submitSampleBuffer:rotation:completion:"), (IMP)hook_submitSampleBuffer, (IMP *)&orig_submitSampleBuffer)) {
                gHookVideo = YES; LOG(@"Hooked %s submitSampleBuffer", class_getName(c));
            }
        }
        if (!gHookSettings) {
            Class c = FindClass("PeerInfoScreenImpl");
            if (c) {
                BOOL a = HookMethod(c, @selector(viewDidAppear:), (IMP)hook_viewDidAppear, (IMP *)&orig_viewDidAppear);
                BOOL b = HookMethod(c, @selector(viewDidDisappear:), (IMP)hook_viewDidDisappear, (IMP *)&orig_viewDidDisappear);
                if (a && b) { gHookSettings = YES; LOG(@"Hooked %s appear/disappear", class_getName(c)); }
            }
        }
        if (!gHookSession) {
            Class c = [AVAudioSession class];
            BOOL a = HookMethod(c, @selector(categoryOptions), (IMP)hook_categoryOptions, (IMP *)&orig_categoryOptions);
            BOOL b = HookMethod(c, @selector(setCategory:mode:options:error:), (IMP)hook_setCategory, (IMP *)&orig_setCategory);
            BOOL d = HookMethod(c, @selector(setCategory:withOptions:error:), (IMP)hook_setCategoryWithOptions, (IMP *)&orig_setCategoryWithOptions);
            BOOL e = HookMethod(c, @selector(setCategory:mode:routeSharingPolicy:options:error:), (IMP)hook_setCategoryRSP, (IMP *)&orig_setCategoryRSP);
            if (a || b || d || e) { gHookSession = YES; LOG(@"Hooked AVAudioSession (%d %d %d %d)", a, b, d, e); }
        }
    }
}

static std::atomic<bool> gPending{false};
static void ScheduleInstall(void) {
    if (gPending.exchange(true)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gPending = false;
        TryInstall();
    });
}
static void ImageAdded(const struct mach_header *h, intptr_t slide) { if (gMicRebindEnabled) RebindImage(h, slide); ScheduleInstall(); }

__attribute__((constructor)) static void TweakInit(void) {
    LOG(@"Dynamic swizzler initializing...");
    LoadPrefs();
    gVisibleProfiles = [NSHashTable weakObjectsHashTable];
    [[NSNotificationCenter defaultCenter] addObserver:[TweakAudioObserver sharedInstance]
                                             selector:@selector(audioRouteChanged:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
    TryInstall();
    _dyld_register_func_for_add_image(ImageAdded);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ TryInstall(); });
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { [[TweakFloat shared] ensure]; ResolveMicFormat(); }];
        if (fabsf(gMicVol.load() - 100.f) >= 0.5f) EnableMicHook();
        ScheduleToast(10);
    });
}
