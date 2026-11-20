#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "layout/layout.h"
#import "window/geometry.h"
#import "window/style.h"

static NSString *const appearanceKey = @"UnipaAppearance";
static NSString *const keepOnTopKey = @"UnipaKeepOnTop";
static NSString *const hideTitleBarKey = @"UnipaHideTitleBar";
static char originalStyleKey;
static NSAppearance *originalAppearance;
static BOOL overridingAppearance;

UnipaAppearance unipaAppearance(void) {
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:appearanceKey];
    if ([saved isEqualToString:@"light"]) return UnipaAppearanceLight;
    if ([saved isEqualToString:@"dark"]) return UnipaAppearanceDark;
    return UnipaAppearanceSystem;
}

BOOL unipaKeepsOnTop(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:keepOnTopKey];
}

BOOL unipaHidesTitleBar(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:hideTitleBarKey];
}

// Apps may set their own style, so unipa keeps it and puts it back when System is chosen.
static void applyAppearance(UnipaAppearance appearance) {
    BOOL system = appearance == UnipaAppearanceSystem;
    if (!system && !overridingAppearance) originalAppearance = NSApp.appearance;
    if (!system || overridingAppearance) {
        NSApp.appearance = system ? originalAppearance :
            [NSAppearance appearanceNamed:appearance == UnipaAppearanceDark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    }
    overridingAppearance = !system;
    // UIKit windows follow overrideUserInterfaceStyle, whose values match UnipaAppearance.
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
    [NSUserDefaults.standardUserDefaults setObject:names[appearance] forKey:appearanceKey];
    applyWindowStyle();
}

void unipaSetKeepsOnTop(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:keepOnTopKey];
    applyWindowStyle();
}

void unipaSetHidesTitleBar(BOOL hidden) {
    [NSUserDefaults.standardUserDefaults setBool:hidden forKey:hideTitleBarKey];
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
