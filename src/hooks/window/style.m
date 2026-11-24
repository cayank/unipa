#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "layout/layout.h"
#import "settings/settings.h"
#import "window/geometry.h"
#import "window/style.h"

static NSString *const appearanceKey = @"UnipaAppearance";
static NSString *const keepOnTopKey = @"UnipaKeepOnTop";
static NSString *const hideTitleBarKey = @"UnipaHideTitleBar";
static char originalStyleKey;
static NSAppearance *originalAppearance;
static BOOL overridingAppearance;

UnipaAppearance unipaAppearance(void) {
    id saved = unipaSettingValue(appearanceKey);
    if ([saved isEqual:@"light"]) return UnipaAppearanceLight;
    if ([saved isEqual:@"dark"]) return UnipaAppearanceDark;
    return UnipaAppearanceSystem;
}

BOOL unipaKeepsOnTop(void) {
    return [unipaSettingValue(keepOnTopKey) boolValue];
}

BOOL unipaHidesTitleBar(void) {
    return [unipaSettingValue(hideTitleBarKey) boolValue];
}

static void applyAppearance(UnipaAppearance appearance) {
    BOOL system = appearance == UnipaAppearanceSystem;
    if (!system && !overridingAppearance) originalAppearance = NSApp.appearance;
    if (!system || overridingAppearance) {
        NSApp.appearance = system ? originalAppearance :
            [NSAppearance appearanceNamed:appearance == UnipaAppearanceDark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    }
    overridingAppearance = !system;
    for (id scene in unipaWindowScenes()) {
        for (id window in [scene valueForKey:@"windows"]) {
            NSNumber *original = objc_getAssociatedObject(window, &originalStyleKey);
            if (system && !original) continue;
            if (!original) objc_setAssociatedObject(window, &originalStyleKey, [window valueForKey:@"overrideUserInterfaceStyle"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [window setValue:system ? original : @(appearance) forKey:@"overrideUserInterfaceStyle"];
            if (system) objc_setAssociatedObject(window, &originalStyleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void applyWindowStyle(void) {
    applyAppearance(unipaAppearance());
    NSWindow *window = unipaMainWindow();
    if (!window) return;
    BOOL hidden = unipaHidesTitleBar();
    window.level = unipaKeepsOnTop() ? NSFloatingWindowLevel : NSNormalWindowLevel;
    window.titleVisibility = hidden ? NSWindowTitleHidden : NSWindowTitleVisible;
    window.titlebarAppearsTransparent = hidden;
}

void unipaSetAppearance(UnipaAppearance appearance) {
    NSArray *names = @[@"system", @"light", @"dark"];
    if (appearance < 0 || appearance >= (NSInteger)names.count) return;
    unipaSetSettingValue(appearanceKey, names[appearance]);
    applyWindowStyle();
}

void unipaSetKeepsOnTop(BOOL enabled) {
    unipaSetSettingValue(keepOnTopKey, @(enabled));
    applyWindowStyle();
}

void unipaSetHidesTitleBar(BOOL hidden) {
    unipaSetSettingValue(hideTitleBarKey, @(hidden));
    applyWindowStyle();
}

__attribute__((constructor)) static void installWindowStyle(void) {
    @autoreleasepool {
        if (unipaPreferredWindowSize().width <= 0) return;
        NSArray<NSNotificationName> *events = @[
            NSWindowDidBecomeKeyNotification,
            @"UISceneDidActivateNotification",
            @"UIWindowDidBecomeVisibleNotification",
        ];
        for (NSNotificationName event in events) {
            [NSNotificationCenter.defaultCenter addObserverForName:event object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
                applyWindowStyle();
            }];
        }
    }
}
