#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "layout/layout.h"
#import "layout/screen.h"
#import "window/geometry.h"

static const CGFloat defaultSceneScale = 0.77;
static BOOL layoutScheduled;

static id sharedApplication(void) {
    Class applicationClass = NSClassFromString(@"UIApplication");
    SEL selector = NSSelectorFromString(@"sharedApplication");
    if (![applicationClass respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(applicationClass, selector);
}

static NSSize fittedSceneSize(NSSize preferred, NSSize available, CGFloat scale) {
    if (preferred.width <= 0 || preferred.height <= 0) return NSZeroSize;
    if (!(scale > 0) || available.width <= 0 || available.height <= 0) return preferred;
    CGFloat fit = MIN(1, MIN(available.width / (preferred.width * scale), available.height / (preferred.height * scale)));
    return NSMakeSize(floor(preferred.width * fit), floor(preferred.height * fit));
}

NSArray *unipaWindowScenes(void) {
    NSMutableArray *scenes = [NSMutableArray array];
    for (id scene in [sharedApplication() valueForKey:@"connectedScenes"]) {
        if ([scene respondsToSelector:NSSelectorFromString(@"sizeRestrictions")]) [scenes addObject:scene];
    }
    return scenes;
}

NSWindow *unipaMainWindow(void) {
    NSWindow *best = nil;
    for (NSWindow *window in NSApp.windows) {
        BOOL level = window.level == NSNormalWindowLevel || window.level == NSFloatingWindowLevel;
        if (!window.visible || !level || window.sheetParent || window.parentWindow || [window isKindOfClass:NSPanel.class]) continue;
        if (!best || window.frame.size.width * window.frame.size.height > best.frame.size.width * best.frame.size.height) best = window;
    }
    return best;
}

static CGFloat sceneScale(NSWindow *window, id scene) {
    if (!window || !scene) return defaultSceneScale;
    NSRect bounds = [[[scene valueForKey:@"coordinateSpace"] valueForKey:@"bounds"] rectValue];
    CGFloat width = [window contentRectForFrameRect:window.frame].size.width;
    if (bounds.size.width <= 0 || width <= 0) return defaultSceneScale;
    CGFloat scale = width / bounds.size.width;
    if (fabs(scale - defaultSceneScale) < 0.02) return defaultSceneScale;
    return scale > 0.25 && scale < 4 ? scale : defaultSceneScale;
}

static CGFloat windowLength(CGFloat target, CGFloat scale) {
    CGFloat lower = floor(target * scale);
    CGFloat upper = ceil(target * scale);
    CGFloat lowerError = fabs(ceil(lower / scale - 0.001) - target);
    CGFloat upperError = fabs(ceil(upper / scale - 0.001) - target);
    return lowerError < upperError ? lower : upper;
}

static NSSize windowContentSize(NSSize target, CGFloat scale) {
    return NSMakeSize(windowLength(target.width, scale), windowLength(target.height, scale));
}

static NSRect windowFrame(NSRect current, NSSize size, NSRect visible) {
    NSRect frame = NSMakeRect(NSMinX(current), NSMaxY(current) - size.height, size.width, size.height);
    frame.origin.x = MAX(NSMinX(visible), MIN(NSMinX(frame), NSMaxX(visible) - size.width));
    frame.origin.y = MAX(NSMinY(visible), MIN(NSMinY(frame), NSMaxY(visible) - size.height));
    return frame;
}

static void applyWindowGeometry(void) {
    unipaRefreshActiveLayout();
    NSArray *scenes = unipaWindowScenes();
    if (!scenes.count) return;
    NSWindow *window = unipaMainWindow();
    CGFloat scale = sceneScale(window, scenes.firstObject);
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    NSSize target = fittedSceneSize(unipaPreferredWindowSize(), screen.visibleFrame.size, scale);
    if (target.width <= 0) return;
    unipaSetDisplaySize(target);
    NSValue *size = [NSValue valueWithSize:target];
    for (id scene in scenes) {
        id restrictions = [scene valueForKey:@"sizeRestrictions"];
        if (!restrictions) continue;
        if (![[restrictions valueForKey:@"minimumSize"] isEqual:size]) [restrictions setValue:size forKey:@"minimumSize"];
        if (![[restrictions valueForKey:@"maximumSize"] isEqual:size]) [restrictions setValue:size forKey:@"maximumSize"];
        if ([restrictions respondsToSelector:NSSelectorFromString(@"setAllowsFullScreen:")]) {
            [restrictions setValue:@NO forKey:@"allowsFullScreen"];
        }
    }
    if (!window) return;
    NSSize content = windowContentSize(target, scale);
    NSSize current = [window contentRectForFrameRect:window.frame].size;
    if (fabs(current.width - content.width) > 0.25 || fabs(current.height - content.height) > 0.25) {
        NSSize size = [window frameRectForContentRect:NSMakeRect(0, 0, content.width, content.height)].size;
        [window setFrame:windowFrame(window.frame, size, screen.visibleFrame) display:YES];
    }
    NSRect scene = [[[scenes.firstObject valueForKey:@"coordinateSpace"] valueForKey:@"bounds"] rectValue];
    if (fabs(scene.size.width - target.width) <= 2 && fabs(scene.size.height - target.height) <= 2) {
        unipaSetDisplaySize(scene.size);
    }
}

void unipaScheduleWindowLayout(void) {
    if (layoutScheduled) return;
    layoutScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        applyWindowGeometry();
        layoutScheduled = NO;
    });
}

__attribute__((constructor)) static void installWindowGeometry(void) {
    @autoreleasepool {
        if (unipaPreferredWindowSize().width <= 0) return;
        NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
        NSArray<NSNotificationName> *events = @[
            NSApplicationDidFinishLaunchingNotification,
            NSApplicationDidChangeScreenParametersNotification,
            NSWindowDidBecomeKeyNotification,
            NSWindowDidResizeNotification,
            NSWindowDidChangeScreenNotification,
            @"UIApplicationDidFinishLaunchingNotification",
            @"UISceneWillConnectNotification",
            @"UISceneDidActivateNotification",
            @"UIWindowDidBecomeVisibleNotification",
        ];
        for (NSNotificationName event in events) {
            [notifications addObserverForName:event object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
                unipaScheduleWindowLayout();
            }];
        }
        unipaScheduleWindowLayout();
    }
}
