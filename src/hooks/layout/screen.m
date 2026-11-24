#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "layout/layout.h"
#import "layout/screen.h"

static NSRect (*originalScreenBounds)(id, SEL);
static NSRect (*originalNativeBounds)(id, SEL);
static NSSize displaySize;

static BOOL validSize(NSSize size) {
    return isfinite(size.width) && isfinite(size.height) && size.width > 0 && size.height > 0;
}

void unipaSetDisplaySize(NSSize size) {
    if (unipaPreferredWindowSize().width <= 0 || !validSize(size)) return;
    displaySize = size;
}

static NSRect screenBounds(id screen, SEL selector) {
    if (!validSize(displaySize)) return originalScreenBounds(screen, selector);
    return NSMakeRect(0, 0, displaySize.width, displaySize.height);
}

static NSRect nativeBounds(id screen, SEL selector) {
    CGFloat scale = ((CGFloat (*)(id, SEL))objc_msgSend)(screen, NSSelectorFromString(@"nativeScale"));
    if (!validSize(displaySize) || !isfinite(scale) || scale <= 0) return originalNativeBounds(screen, selector);
    return NSMakeRect(0, 0, round(displaySize.width * scale), round(displaySize.height * scale));
}

__attribute__((constructor)) static void installScreen(void) {
    @autoreleasepool {
        NSSize preferred = unipaPreferredWindowSize();
        if (preferred.width <= 0) return;
        displaySize = preferred;
        Class screenClass = NSClassFromString(@"UIScreen");
        Method bounds = class_getInstanceMethod(screenClass, NSSelectorFromString(@"bounds"));
        Method native = class_getInstanceMethod(screenClass, NSSelectorFromString(@"nativeBounds"));
        if (bounds) {
            originalScreenBounds = (NSRect (*)(id, SEL))method_getImplementation(bounds);
            method_setImplementation(bounds, (IMP)screenBounds);
        }
        if (native) {
            originalNativeBounds = (NSRect (*)(id, SEL))method_getImplementation(native);
            method_setImplementation(native, (IMP)nativeBounds);
        }
    }
}
