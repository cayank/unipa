#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "display-geometry.h"

static NSRect (*originalScreenBounds)(id, SEL);
static NSRect (*originalNativeBounds)(id, SEL);
static NSMapTable *primaryWindows;
static char viewportKey;
static char viewportHistoryKey;
static _Thread_local BOOL readingViewport;

NSSize unipaPreferredWindowSize(void) {
    static NSSize size;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id profile = NSBundle.mainBundle.infoDictionary[@"UnipaDisplay"];
        if (![profile isKindOfClass:NSDictionary.class]) return;
        id width = profile[@"width"];
        id height = profile[@"height"];
        if (![width isKindOfClass:NSNumber.class] || ![height isKindOfClass:NSNumber.class]) return;
        double w = [width doubleValue];
        double h = [height doubleValue];
        if (isfinite(w) && isfinite(h) && w > 0 && h > 0 && w <= 16384 && h <= 16384) {
            size = NSMakeSize(w, h);
        }
    });
    return size;
}

static BOOL validViewport(NSRect bounds) {
    return isfinite(bounds.size.width) && isfinite(bounds.size.height) && bounds.size.width > 0 && bounds.size.height > 0;
}

static void rememberViewport(id screen, NSRect bounds) {
    if (!screen || !validViewport(bounds)) return;
    bounds.origin = NSZeroPoint;
    NSValue *previous = objc_getAssociatedObject(screen, &viewportKey);
    if (previous && NSEqualRects(previous.rectValue, bounds)) return;
    NSArray<NSValue *> *saved = objc_getAssociatedObject(screen, &viewportHistoryKey);
    NSMutableArray<NSValue *> *history = saved ? saved.mutableCopy : [NSMutableArray array];
    if (!saved && originalScreenBounds) {
        NSRect physical = originalScreenBounds(screen, NSSelectorFromString(@"bounds"));
        if (validViewport(physical)) [history addObject:[NSValue valueWithRect:physical]];
    }
    if (previous && ![history containsObject:previous]) [history addObject:previous];
    while (history.count > 8) [history removeObjectAtIndex:0];
    objc_setAssociatedObject(screen, &viewportHistoryKey, history.copy, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(screen, &viewportKey, [NSValue valueWithRect:bounds], OBJC_ASSOCIATION_RETAIN);
}

static BOOL isPrimaryCandidate(id window, id screen) {
    if (!window || [window valueForKey:@"screen"] != screen) return NO;
    if ([[window valueForKey:@"hidden"] boolValue] || fabs([[window valueForKey:@"windowLevel"] doubleValue]) > 0.01) return NO;
    id controller = [window valueForKey:@"rootViewController"];
    if (!controller || [controller valueForKey:@"presentingViewController"]) return NO;
    if ([[controller valueForKey:@"isViewLoaded"] boolValue]) {
        id owner = [[controller valueForKey:@"view"] valueForKey:@"window"];
        if (owner && owner != window) return NO;
    }
    return YES;
}

void unipaUpdateDisplayGeometry(id window) {
    if (!NSThread.isMainThread || !window) return;
    id screen = [window valueForKey:@"screen"];
    if (!isPrimaryCandidate(window, screen)) return;
    id primary = [primaryWindows objectForKey:screen];
    if (primary != window && isPrimaryCandidate(primary, screen)) return;
    [primaryWindows setObject:window forKey:screen];
    rememberViewport(screen, [[window valueForKey:@"bounds"] rectValue]);
}

BOOL unipaIsDisplayBounds(id screen, NSRect bounds) {
    if (!screen || !validViewport(bounds) || fabs(bounds.origin.x) > 0.5 || fabs(bounds.origin.y) > 0.5) return NO;
    NSMutableArray<NSValue *> *values = [NSMutableArray array];
    NSValue *current = objc_getAssociatedObject(screen, &viewportKey);
    if (current) [values addObject:current];
    NSArray<NSValue *> *history = objc_getAssociatedObject(screen, &viewportHistoryKey);
    if (history) [values addObjectsFromArray:history];
    for (NSValue *value in values) {
        NSSize size = value.rectValue.size;
        if (fabs(size.width - bounds.size.width) <= 0.5 && fabs(size.height - bounds.size.height) <= 0.5) return YES;
    }
    return NO;
}

static NSValue *currentViewport(id screen) {
    if (NSThread.isMainThread && !readingViewport) {
        readingViewport = YES;
        @try {
            id primary = [primaryWindows objectForKey:screen];
            if (isPrimaryCandidate(primary, screen)) {
                unipaUpdateDisplayGeometry(primary);
            } else {
                Class applicationClass = NSClassFromString(@"UIApplication");
                SEL shared = NSSelectorFromString(@"sharedApplication");
                if ([applicationClass respondsToSelector:shared]) {
                    id application = ((id (*)(id, SEL))objc_msgSend)(applicationClass, shared);
                    NSMutableOrderedSet *windows = [NSMutableOrderedSet orderedSet];
                    for (id scene in [application valueForKey:@"connectedScenes"]) {
                        if ([scene respondsToSelector:NSSelectorFromString(@"windows")]) {
                            [windows addObjectsFromArray:[scene valueForKey:@"windows"]];
                        }
                    }
                    if ([application respondsToSelector:NSSelectorFromString(@"windows")]) {
                        [windows addObjectsFromArray:[application valueForKey:@"windows"]];
                    }
                    id candidate = nil;
                    for (id window in windows) {
                        if (!isPrimaryCandidate(window, screen)) continue;
                        if (!candidate) candidate = window;
                        if ([[window valueForKey:@"isKeyWindow"] boolValue]) {
                            candidate = window;
                            break;
                        }
                    }
                    unipaUpdateDisplayGeometry(candidate);
                }
            }
        } @finally {
            readingViewport = NO;
        }
    }
    return objc_getAssociatedObject(screen, &viewportKey);
}

static NSRect screenBounds(id screen, SEL selector) {
    NSValue *value = currentViewport(screen);
    return value ? value.rectValue : originalScreenBounds(screen, selector);
}

static NSRect nativeBounds(id screen, SEL selector) {
    NSValue *value = currentViewport(screen);
    if (!value) return originalNativeBounds(screen, selector);
    CGFloat scale = ((CGFloat (*)(id, SEL))objc_msgSend)(screen, NSSelectorFromString(@"nativeScale"));
    if (!isfinite(scale) || scale <= 0) return originalNativeBounds(screen, selector);
    NSRect bounds = value.rectValue;
    return NSMakeRect(0, 0, round(bounds.size.width * scale), round(bounds.size.height * scale));
}

__attribute__((constructor)) static void installDisplayGeometry(void) {
    @autoreleasepool {
        NSSize preferred = unipaPreferredWindowSize();
        if (preferred.width <= 0) return;
        primaryWindows = [NSMapTable weakToWeakObjectsMapTable];
        Class screenClass = NSClassFromString(@"UIScreen");
        Method bounds = class_getInstanceMethod(screenClass, NSSelectorFromString(@"bounds"));
        Method native = class_getInstanceMethod(screenClass, NSSelectorFromString(@"nativeBounds"));
        if (bounds) originalScreenBounds = (NSRect (*)(id, SEL))method_getImplementation(bounds);
        if (native) originalNativeBounds = (NSRect (*)(id, SEL))method_getImplementation(native);
        SEL main = NSSelectorFromString(@"mainScreen");
        if ([screenClass respondsToSelector:main]) {
            id screen = ((id (*)(id, SEL))objc_msgSend)(screenClass, main);
            rememberViewport(screen, NSMakeRect(0, 0, preferred.width, preferred.height));
        }
        if (bounds) method_setImplementation(bounds, (IMP)screenBounds);
        if (native) method_setImplementation(native, (IMP)nativeBounds);
    }
}
