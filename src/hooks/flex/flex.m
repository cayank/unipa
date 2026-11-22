#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "layout/layout.h"

static BOOL flexCanBecomeKey(id self, SEL _cmd) {
    return YES;
}

static void installFlexCatalystFix(void) {
    Class flexWindow = NSClassFromString(@"FLEXWindow");
    if (!flexWindow) return;
    Method method = class_getInstanceMethod(flexWindow, @selector(canBecomeKeyWindow));
    if (method) method_setImplementation(method, (IMP)flexCanBecomeKey);
}

__attribute__((constructor)) static void scheduleFlexCatalystFix(void) {
    if (unipaPreferredWindowSize().width <= 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            installFlexCatalystFix();
        }
    });
}
