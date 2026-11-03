#import <AppKit/AppKit.h>
#import <objc/message.h>

static const CGFloat windowWidth = 390;
static const CGFloat windowHeight = 844;
static NSHashTable *configuredScenes;
static NSHashTable<NSWindow *> *configuredWindows;

static void allowSceneResizing(void) {
    Class applicationClass = NSClassFromString(@"UIApplication");
    if (![applicationClass respondsToSelector:NSSelectorFromString(@"sharedApplication")]) return;
    id application = ((id (*)(id, SEL))objc_msgSend)(applicationClass, NSSelectorFromString(@"sharedApplication"));
    for (id scene in [application valueForKey:@"connectedScenes"]) {
        if ([configuredScenes containsObject:scene] || ![scene respondsToSelector:NSSelectorFromString(@"sizeRestrictions")]) continue;
        id restrictions = [scene valueForKey:@"sizeRestrictions"];
        if (!restrictions) continue;

        [restrictions setValue:[NSValue valueWithSize:NSMakeSize(320, 320 * windowHeight / windowWidth)] forKey:@"minimumSize"];
        [restrictions setValue:[NSValue valueWithSize:NSMakeSize(10000, 10000)] forKey:@"maximumSize"];

        if ([restrictions respondsToSelector:NSSelectorFromString(@"setAllowsFullScreen:")]) {
            [restrictions setValue:@NO forKey:@"allowsFullScreen"];
        }

        [configuredScenes addObject:scene];
    }
}

static NSSize minimumWindowSize(NSWindow *window) {
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    if (!screen) return NSMakeSize(windowWidth, windowHeight);

    NSRect frame = [window frameRectForContentRect:NSMakeRect(0, 0, windowWidth, windowHeight)];
    CGFloat titleBarHeight = frame.size.height - windowHeight;
    NSSize available = screen.visibleFrame.size;
    CGFloat scale = MIN(1, MIN(available.width / windowWidth, (available.height - titleBarHeight) / windowHeight));

    return NSMakeSize(windowWidth * scale, windowHeight * scale);
}

static void enforceWindowGeometry(NSWindow *window) {
    NSSize size = [window contentRectForFrameRect:window.frame].size;
    NSSize minimum = minimumWindowSize(window);
    window.contentMinSize = minimum;

    CGFloat width = MAX(size.width, minimum.width);
    CGFloat height = width * windowHeight / windowWidth;

    if (fabs(size.width - width) > 1 || fabs(size.height - height) > 1) {
        [window setContentSize:NSMakeSize(width, height)];
    }
}

static void configureWindows(void) {
    allowSceneResizing();
    for (NSWindow *window in NSApp.windows) {
        if (!window.visible || window.level != NSNormalWindowLevel || window.sheetParent || [window isKindOfClass:NSPanel.class]) continue;
        window.contentAspectRatio = NSMakeSize(windowWidth, windowHeight);

        if ([configuredWindows containsObject:window]) continue;
        [configuredWindows addObject:window];

        window.styleMask |= NSWindowStyleMaskResizable;
        NSSize minimum = minimumWindowSize(window);
        window.contentMinSize = minimum;
        [window setContentSize:minimum];
        [window center];
    }
}

__attribute__((constructor)) static void installWindowGeometry(void) {
    @autoreleasepool {
        configuredScenes = NSHashTable.weakObjectsHashTable;
        configuredWindows = NSHashTable.weakObjectsHashTable;
        NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
        NSArray<NSNotificationName> *events = @[
            NSApplicationDidFinishLaunchingNotification,
            NSWindowDidBecomeKeyNotification,
            @"UIApplicationDidFinishLaunchingNotification",
            @"UISceneDidActivateNotification",
            @"UIWindowDidBecomeVisibleNotification",
        ];
        for (NSNotificationName event in events) {
            [notifications addObserverForName:event object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                dispatch_async(dispatch_get_main_queue(), ^{ configureWindows(); });
            }];
        }
        [notifications addObserverForName:NSWindowDidResizeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            NSWindow *window = notification.object;
            if ([configuredWindows containsObject:window]) enforceWindowGeometry(window);
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            configureWindows();
        });
    }
}
