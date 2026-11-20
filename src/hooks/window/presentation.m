#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "layout/layout.h"

static NSString *applicationRoot;
static void (*originalSetStyle)(id, SEL, NSInteger);
static id (*originalPresentation)(id, SEL);

static BOOL isApplicationController(id controller, NSUInteger depth) {
    if (!controller || depth > 4) return NO;
    Class base = NSClassFromString(@"UIViewController");
    Class navigation = NSClassFromString(@"UINavigationController");
    Class tabs = NSClassFromString(@"UITabBarController");
    for (Class type = object_getClass(controller); type && type != base; type = class_getSuperclass(type)) {
        if (type == navigation || type == tabs) continue;
        const char *image = class_getImageName(type);
        if (!image) continue;
        NSString *path = [[NSString stringWithUTF8String:image] stringByResolvingSymlinksInPath];
        if ([path hasPrefix:applicationRoot]) return YES;
    }
    if ((navigation && [controller isKindOfClass:navigation]) || (tabs && [controller isKindOfClass:tabs])) {
        NSArray *children = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"viewControllers"));
        NSUInteger count = MIN(children.count, 16);
        for (NSUInteger index = 0; index < count; index++) {
            if (isApplicationController(children[index], depth + 1)) return YES;
        }
    }
    return NO;
}

// UIModalPresentationOverFullScreen covers the window like a sheet would, without removing the screen underneath.
// A full-screen presentation would make a tab bar controller disappear and drop its Mac toolbar tabs.
static const NSInteger inWindowStyle = 5;

static BOOL isSheetStyle(NSInteger style) {
    return style == -2 || style == 1 || style == 2;
}

static void setPresentationStyle(id controller, SEL selector, NSInteger style) {
    if (isSheetStyle(style) && isApplicationController(controller, 0)) style = inWindowStyle;
    originalSetStyle(controller, selector, style);
}

static id presentationController(id controller, SEL selector) {
    if (isApplicationController(controller, 0)) {
        id parent = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"presentingViewController"));
        if (!parent) {
            NSInteger style = ((NSInteger (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"modalPresentationStyle"));
            if (isSheetStyle(style)) {
                originalSetStyle(controller, NSSelectorFromString(@"setModalPresentationStyle:"), inWindowStyle);
            }
        }
    }
    return originalPresentation(controller, selector);
}

__attribute__((constructor)) static void installPresentationPolicy(void) {
    @autoreleasepool {
        if (unipaPreferredWindowSize().width <= 0) return;
        applicationRoot = [NSBundle.mainBundle.bundlePath.stringByResolvingSymlinksInPath stringByAppendingString:@"/"];
        Class controller = NSClassFromString(@"UIViewController");
        Method setter = class_getInstanceMethod(controller, NSSelectorFromString(@"setModalPresentationStyle:"));
        Method getter = class_getInstanceMethod(controller, NSSelectorFromString(@"presentationController"));
        if (!setter || !getter) return;
        originalSetStyle = (void (*)(id, SEL, NSInteger))method_getImplementation(setter);
        originalPresentation = (id (*)(id, SEL))method_getImplementation(getter);
        method_setImplementation(setter, (IMP)setPresentationStyle);
        // Choose the style before UIKit caches a native sheet presentation controller.
        method_setImplementation(getter, (IMP)presentationController);
    }
}
