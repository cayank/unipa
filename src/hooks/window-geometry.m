#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "display-geometry.h"

static NSHashTable *configuredScenes;
static NSHashTable<NSWindow *> *configuredWindows;
static BOOL layoutScheduled;
static BOOL applyingGeometry;
static char fullWindowFrameKey;
static void (*originalPresentController)(id, SEL, id, BOOL, void (^)(void));

static void scheduleWindowLayout(void);

static id sharedApplication(void) {
    Class applicationClass = NSClassFromString(@"UIApplication");
    SEL selector = NSSelectorFromString(@"sharedApplication");
    if (![applicationClass respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(applicationClass, selector);
}

static void allowSceneResizing(void) {
    NSSize preferred = unipaPreferredWindowSize();
    for (id scene in [sharedApplication() valueForKey:@"connectedScenes"]) {
        if ([configuredScenes containsObject:scene] || ![scene respondsToSelector:NSSelectorFromString(@"sizeRestrictions")]) continue;
        id restrictions = [scene valueForKey:@"sizeRestrictions"];
        if (!restrictions) continue;
        [restrictions setValue:[NSValue valueWithSize:NSMakeSize(320, 320 * preferred.height / preferred.width)] forKey:@"minimumSize"];
        [restrictions setValue:[NSValue valueWithSize:NSMakeSize(10000, 10000)] forKey:@"maximumSize"];
        if ([restrictions respondsToSelector:NSSelectorFromString(@"setAllowsFullScreen:")]) {
            [restrictions setValue:@NO forKey:@"allowsFullScreen"];
        }
        [configuredScenes addObject:scene];
    }
}

static NSSize contentInsets(NSWindow *window) {
    NSSize content = [window contentRectForFrameRect:window.frame].size;
    NSSize layout = window.contentLayoutRect.size;
    if (layout.width <= 0 || layout.height <= 0) return NSZeroSize;
    return NSMakeSize(MAX(0, content.width - layout.width), MAX(0, content.height - layout.height));
}

static NSSize minimumWindowSize(NSWindow *window) {
    NSSize preferred = unipaPreferredWindowSize();
    NSSize insets = contentInsets(window);
    NSRect content = NSMakeRect(0, 0, preferred.width + insets.width, preferred.height + insets.height);
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    if (!screen) return content.size;
    NSRect frame = [window frameRectForContentRect:content];
    NSSize available = screen.visibleFrame.size;
    CGFloat chromeWidth = frame.size.width - preferred.width;
    CGFloat chromeHeight = frame.size.height - preferred.height;
    CGFloat scale = MIN(1, MIN((available.width - chromeWidth) / preferred.width, (available.height - chromeHeight) / preferred.height));
    if (scale <= 0) return content.size;
    return NSMakeSize(preferred.width * scale + insets.width, preferred.height * scale + insets.height);
}

static void enforceWindowGeometry(NSWindow *window) {
    NSSize preferred = unipaPreferredWindowSize();
    if (applyingGeometry) return;
    applyingGeometry = YES;
    NSSize size = [window contentRectForFrameRect:window.frame].size;
    NSSize insets = contentInsets(window);
    NSSize minimum = minimumWindowSize(window);
    CGFloat width = MAX(size.width, minimum.width);
    CGFloat height = (width - insets.width) * preferred.height / preferred.width + insets.height;
    window.contentMinSize = minimum;
    window.contentAspectRatio = NSMakeSize(width, height);
    if (fabs(size.width - width) > 1 || fabs(size.height - height) > 1) {
        [window setContentSize:NSMakeSize(width, height)];
    }
    applyingGeometry = NO;
}

static BOOL rectChanged(NSRect current, NSRect target) {
    return fabs(current.origin.x - target.origin.x) > 0.5 || fabs(current.origin.y - target.origin.y) > 0.5 ||
           fabs(current.size.width - target.size.width) > 0.5 || fabs(current.size.height - target.size.height) > 0.5;
}

static void fitView(id view, NSRect frame) {
    CGAffineTransform transform = ((CGAffineTransform (*)(id, SEL))objc_msgSend)(view, NSSelectorFromString(@"transform"));
    if (!CGAffineTransformIsIdentity(transform)) return;
    NSRect previous = [[view valueForKey:@"frame"] rectValue];
    if (rectChanged(previous, frame)) {
        [view setValue:[NSValue valueWithRect:frame] forKey:@"frame"];
        ((void (*)(id, SEL))objc_msgSend)(view, NSSelectorFromString(@"setNeedsLayout"));
    }
}

static void fitControllerView(id controller, NSRect bounds) {
    if (!controller || ![[controller valueForKey:@"isViewLoaded"] boolValue]) return;
    fitView([controller valueForKey:@"view"], bounds);
}

static void fitPresentedView(id controller, id window) {
    NSRect windowBounds = [[window valueForKey:@"bounds"] rectValue];
    if ([controller valueForKey:@"parentViewController"] || ![[controller valueForKey:@"isViewLoaded"] boolValue]) return;
    id view = [controller valueForKey:@"view"];
    id owner = [view valueForKey:@"window"];
    // A detached sheet belongs to a different native window.
    if (owner && owner != window) return;
    id presentation = [controller valueForKey:@"presentationController"];
    id container = [presentation valueForKey:@"containerView"];
    if (container) {
        NSRect frame = ((NSRect (*)(id, SEL))objc_msgSend)(presentation, NSSelectorFromString(@"frameOfPresentedViewInContainerView"));
        NSRect bounds = [[container valueForKey:@"bounds"] rectValue];
        NSInteger style = [[controller valueForKey:@"modalPresentationStyle"] integerValue];
        NSValue *known = objc_getAssociatedObject(presentation, &fullWindowFrameKey);
        BOOL previousViewport = known && !rectChanged(known.rectValue, frame);
        id screen = [window valueForKey:@"screen"];
        if (style == 4 && (previousViewport || unipaIsDisplayBounds(screen, frame))) {
            // Some custom presenters cache the display size when they are created.
            objc_setAssociatedObject(presentation, &fullWindowFrameKey, [NSValue valueWithRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (id background in [container valueForKey:@"subviews"]) {
                NSRect old = [[background valueForKey:@"frame"] rectValue];
                if (!rectChanged(old, frame) || (known && !rectChanged(old, known.rectValue)) || unipaIsDisplayBounds(screen, old)) {
                    fitView(background, bounds);
                }
            }
            frame = bounds;
        } else if (known) {
            objc_setAssociatedObject(presentation, &fullWindowFrameKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!NSIsEmptyRect(frame) && NSContainsRect(NSInsetRect(bounds, -1, -1), frame)) {
            id parent = [view valueForKey:@"superview"];
            if (parent && parent != container) {
                frame = ((NSRect (*)(id, SEL, NSRect, id))objc_msgSend)(parent, NSSelectorFromString(@"convertRect:fromView:"), frame, container);
            }
            fitControllerView(controller, frame);
            return;
        }
    }
    NSInteger style = [[controller valueForKey:@"modalPresentationStyle"] integerValue];
    if (style == 0 || style == 5) fitControllerView(controller, windowBounds);
}

static void fitUIKitWindow(id window) {
    if ([[window valueForKey:@"hidden"] boolValue] || fabs([[window valueForKey:@"windowLevel"] doubleValue]) > 0.01) return;
    id controller = [window valueForKey:@"rootViewController"];
    if (!controller) return;
    if ([controller valueForKey:@"presentingViewController"]) {
        // UIKit owns the geometry of a presentation moved into its own window.
        return;
    }

    // Scene bounds use UIKit points, which may differ from AppKit points in Catalyst.
    id scene = [window valueForKey:@"windowScene"];
    id space = [scene valueForKey:@"coordinateSpace"];
    NSRect viewport = [[space valueForKey:@"bounds"] rectValue];
    if (space && viewport.size.width > 0 && viewport.size.height > 0) {
        NSRect frame = [[window valueForKey:@"frame"] rectValue];
        if (rectChanged(frame, viewport)) {
            [window setValue:[NSValue valueWithRect:viewport] forKey:@"frame"];
        }
    }

    NSRect bounds = [[window valueForKey:@"bounds"] rectValue];
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
    unipaUpdateDisplayGeometry(window);
    fitControllerView(controller, bounds);
    for (id presented = [controller valueForKey:@"presentedViewController"]; presented;
         presented = [presented valueForKey:@"presentedViewController"]) {
        fitPresentedView(presented, window);
    }
    ((void (*)(id, SEL))objc_msgSend)(window, NSSelectorFromString(@"setNeedsLayout"));
    ((void (*)(id, SEL))objc_msgSend)(window, NSSelectorFromString(@"layoutIfNeeded"));
}

static void fitUIKitWindows(void) {
    id application = sharedApplication();
    NSMutableSet *windows = [NSMutableSet set];
    for (id scene in [application valueForKey:@"connectedScenes"]) {
        if ([scene respondsToSelector:NSSelectorFromString(@"windows")]) {
            [windows addObjectsFromArray:[scene valueForKey:@"windows"]];
        }
    }
    // Include windows hosted outside the application's main scenes.
    if ([application respondsToSelector:NSSelectorFromString(@"windows")]) {
        [windows addObjectsFromArray:[application valueForKey:@"windows"]];
    }
    for (id window in windows) fitUIKitWindow(window);
}

static void configureWindows(void) {
    allowSceneResizing();
    for (NSWindow *window in NSApp.windows) {
        if (!window.visible || window.level != NSNormalWindowLevel || window.sheetParent || window.parentWindow || [window isKindOfClass:NSPanel.class]) continue;
        if ([configuredWindows containsObject:window]) {
            enforceWindowGeometry(window);
            continue;
        }
        [configuredWindows addObject:window];
        applyingGeometry = YES;
        window.styleMask |= NSWindowStyleMaskResizable;
        [window setContentSize:minimumWindowSize(window)];
        applyingGeometry = NO;
        enforceWindowGeometry(window);
        [window center];
    }
}

static void scheduleWindowLayout(void) {
    if (layoutScheduled) return;
    layoutScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        configureWindows();
        fitUIKitWindows();
        // Catalyst can update its scene bounds after the native window resize.
        dispatch_async(dispatch_get_main_queue(), ^{
            fitUIKitWindows();
            layoutScheduled = NO;
        });
    });
}

static void presentController(id controller, SEL selector, id presented, BOOL animated, void (^completion)(void)) {
    originalPresentController(controller, selector, presented, animated, ^{
        if (completion) completion();
        scheduleWindowLayout();
    });
}

__attribute__((constructor)) static void installWindowGeometry(void) {
    @autoreleasepool {
        if (unipaPreferredWindowSize().width <= 0) return;
        configuredScenes = NSHashTable.weakObjectsHashTable;
        configuredWindows = NSHashTable.weakObjectsHashTable;
        Class controllerClass = NSClassFromString(@"UIViewController");
        SEL presentation = NSSelectorFromString(@"presentViewController:animated:completion:");
        Method method = class_getInstanceMethod(controllerClass, presentation);
        if (method) {
            originalPresentController = (void (*)(id, SEL, id, BOOL, void (^)(void)))method_getImplementation(method);
            method_setImplementation(method, (IMP)presentController);
        }
        NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
        NSArray<NSNotificationName> *events = @[
            NSApplicationDidFinishLaunchingNotification,
            NSWindowDidBecomeKeyNotification,
            NSWindowDidEndLiveResizeNotification,
            NSWindowDidChangeScreenNotification,
            NSWindowDidChangeBackingPropertiesNotification,
            @"UIApplicationDidFinishLaunchingNotification",
            @"UISceneDidActivateNotification",
            @"UIWindowDidBecomeVisibleNotification",
            @"UIWindowDidBecomeKeyNotification",
        ];
        for (NSNotificationName event in events) {
            [notifications addObserverForName:event object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
                scheduleWindowLayout();
            }];
        }
        [notifications addObserverForName:NSWindowDidResizeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            NSWindow *window = notification.object;
            if ([configuredWindows containsObject:window]) {
                enforceWindowGeometry(window);
                scheduleWindowLayout();
            }
        }];
        scheduleWindowLayout();
    }
}
