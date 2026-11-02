// TelegramCallTweak — rewritten source.
// Behaviour reconstructed from the compiled TelegramCallTweak.dylib (original by oceanondawave):
//   * "Call Tweak Settings" entry on the Telegram Settings screen
//   * Force built-in mic (keeps Bluetooth/headphones for output only)
//   * Share Audio Only (drops screen-share video frames, keeps the audio)
//   * Screen media volume / microphone volume
//
// Everything is resolved at runtime (class lookup by name, hooks installed with retries),
// so a renamed Swift module prefix or a late-loaded image no longer breaks the tweak.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <atomic>
#import <math.h>

#define LOG(fmt, ...) NSLog(@"[TelegramCallTweak] " fmt, ##__VA_ARGS__)

// ---- layout of the floating button on the Settings screen (adjust if it overlaps) ----
#define BTN_WIDTH        200.0
#define BTN_HEIGHT       34.0
#define BTN_BOTTOM_GAP   (49.0 + 16.0)   // tab bar + margin
#define BTN_TAG          0xCA11

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
    gForceMic  = [gPrefs[kForceMic] boolValue];
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

// Best effort: iOS only lets us change input gain when the current input reports it as settable.
static void ApplyMicGain(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance;
    if (!s.isInputGainSettable) return;
    float g = fminf(1.f, fmaxf(0.f, gMicVol.load() / 100.f));
    [s setInputGain:g error:nil];
}

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
    dispatch_async(dispatch_get_main_queue(), ^{ ApplyBuiltInMic(); ApplyMicGain(); });
}
@end

static AVAudioSessionCategoryOptions (*orig_categoryOptions)(id, SEL);
static AVAudioSessionCategoryOptions hook_categoryOptions(id self, SEL _cmd) {
    AVAudioSessionCategoryOptions o = orig_categoryOptions(self, _cmd);
    if (gForceMic) o &= ~kAllowBluetoothHFP;
    return o;
}

static BOOL (*orig_setCategory)(id, SEL, NSString *, NSString *, AVAudioSessionCategoryOptions, NSError **);
static BOOL hook_setCategory(id self, SEL _cmd, NSString *cat, NSString *mode,
                             AVAudioSessionCategoryOptions opts, NSError **err) {
    if (gForceMic && [cat isEqualToString:AVAudioSessionCategoryPlayAndRecord]) opts &= ~kAllowBluetoothHFP;
    BOOL r = orig_setCategory(self, _cmd, cat, mode, opts, err);
    if (r) dispatch_async(dispatch_get_main_queue(), ^{ ApplyBuiltInMic(); ApplyMicGain(); });
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

static UIViewController *TopViewController(void) {
    UIWindow *w = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *x in ((UIWindowScene *)sc).windows) if (x.isKeyWindow) { w = x; break; }
        if (w) break;
    }
    UIViewController *v = w.rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
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
        s.maximumValue = mic ? 100 : 200;   // mic gain can't exceed the hardware maximum
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
        ApplyMicGain();
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
    self.micLabel.text = [NSString stringWithFormat:@"Microphone Voice Volume (%.0f%%)", v];
    ApplyMicGain();
}
- (void)mediaSliderChanged:(UISlider *)s {
    float v = roundf(s.value);
    gMediaVol = v; SavePref(kMediaVol, @(v));
    self.mediaLabel.text = [NSString stringWithFormat:@"Screen Media Volume (%.0f%%)", v];
}
@end

@interface TweakActions : NSObject
+ (void)openCallTweakSettingsModally;
@end
@implementation TweakActions
+ (void)openCallTweakSettingsModally {
    TweakSettingsViewController *vc = [TweakSettingsViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [TopViewController() presentViewController:nav animated:YES completion:nil];
}
@end

// Adds the "Call Tweak Settings" button to the root Settings screen (PeerInfoScreenImpl).
static void (*orig_viewDidLayoutSubviews)(id, SEL);
static void hook_viewDidLayoutSubviews(UIViewController *self, SEL _cmd) {
    orig_viewDidLayoutSubviews(self, _cmd);

    if (!strstr(class_getName(object_getClass(self)), "PeerInfoScreenImpl")) return;
    UIViewController *nav = self.navigationController;
    if (!nav || ![nav respondsToSelector:@selector(viewControllers)]) return;
    NSArray *stack = [nav performSelector:@selector(viewControllers)];
    if (stack.firstObject != self) return;            // only the Settings tab root, not pushed profiles

    UIView *host = self.view;
    UIButton *b = (UIButton *)[host viewWithTag:BTN_TAG];
    if (!b) {
        b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = BTN_TAG;
        [b setTitle:@"Call Tweak Settings" forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        b.backgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.95];
        b.layer.cornerRadius = BTN_HEIGHT / 2;
        b.layer.borderWidth = 0.5;
        b.layer.borderColor = UIColor.separatorColor.CGColor;
        [b addTarget:[TweakActions class] action:@selector(openCallTweakSettingsModally)
            forControlEvents:UIControlEventTouchUpInside];
        [host addSubview:b];
    }
    CGRect r = host.bounds;
    b.frame = CGRectMake((r.size.width - BTN_WIDTH) / 2.0,
                         r.size.height - host.safeAreaInsets.bottom - BTN_BOTTOM_GAP - BTN_HEIGHT,
                         BTN_WIDTH, BTN_HEIGHT);
    [host bringSubviewToFront:b];
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
    static BOOL dAudio, dVideo, dSession, dVC;
    @synchronized ([TweakActions class]) {
        if (!dAudio) {
            Class c = FindClass("OngoingCallThreadLocalContextWebrtc");
            if (c && HookMethod(c, NSSelectorFromString(@"addExternalAudioData:"), (IMP)hook_addExternalAudioData, (IMP *)&orig_addExternalAudioData)) {
                dAudio = YES; LOG(@"Hooked %s addExternalAudioData:", class_getName(c));
            }
        }
        if (!dVideo) {
            Class c = FindClass("OngoingCallThreadLocalContextVideoCapturer");
            if (c && HookMethod(c, NSSelectorFromString(@"submitSampleBuffer:rotation:completion:"), (IMP)hook_submitSampleBuffer, (IMP *)&orig_submitSampleBuffer)) {
                dVideo = YES; LOG(@"Hooked %s submitSampleBuffer", class_getName(c));
            }
        }
        if (!dSession) {
            Class c = [AVAudioSession class];
            BOOL a = HookMethod(c, @selector(categoryOptions), (IMP)hook_categoryOptions, (IMP *)&orig_categoryOptions);
            BOOL b = HookMethod(c, @selector(setCategory:mode:options:error:), (IMP)hook_setCategory, (IMP *)&orig_setCategory);
            if (a && b) { dSession = YES; LOG(@"Hooked AVAudioSession"); }
        }
        if (!dVC) {
            Class c = FindClass("PeerInfoScreenImpl");
            if (!c) c = [UIViewController class];     // fallback: filtered by class name in the hook
            if (HookMethod(c, @selector(viewDidLayoutSubviews), (IMP)hook_viewDidLayoutSubviews, (IMP *)&orig_viewDidLayoutSubviews)) {
                dVC = YES; LOG(@"Hooked viewDidLayoutSubviews on %s", class_getName(c));
            }
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
static void ImageAdded(const struct mach_header *h, intptr_t slide) { ScheduleInstall(); }

__attribute__((constructor)) static void TweakInit(void) {
    LOG(@"Dynamic swizzler initializing...");
    LoadPrefs();
    [[NSNotificationCenter defaultCenter] addObserver:[TweakAudioObserver sharedInstance]
                                             selector:@selector(audioRouteChanged:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
    TryInstall();
    _dyld_register_func_for_add_image(ImageAdded);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ TryInstall(); });
}
