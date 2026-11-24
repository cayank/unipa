#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "layout/layout.h"

static void (*originalUpdateToolbar)(id, SEL, id);
static void (*originalViewDidAppear)(id, SEL, BOOL);

static id macStyle(id controller) {
    id style = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"_visualStyle"));
    return [style isKindOfClass:NSClassFromString(@"_UITabBarControllerVisualStyle_Mac")] ? style : nil;
}

static void updateToolbar(id style, SEL selector, id window) {
    if (window && ![style valueForKey:@"segmentedControl"]) {
        ((void (*)(id, SEL))objc_msgSend)(style, NSSelectorFromString(@"_updateSegmentedControl"));
    }
    originalUpdateToolbar(style, selector, window);
}

static void viewDidAppear(id controller, SEL selector, BOOL animated) {
    originalViewDidAppear(controller, selector, animated);
    ((void (*)(id, SEL))objc_msgSend)(macStyle(controller), NSSelectorFromString(@"updateTabBarLayout"));
}

__attribute__((constructor)) static void installTabs(void) {
    @autoreleasepool {
        if (unipaPreferredWindowSize().width <= 0) return;
        Class style = NSClassFromString(@"_UITabBarControllerVisualStyle_Mac");
        Method update = class_getInstanceMethod(style, NSSelectorFromString(@"_updateToolbarForWindow:"));
        if (!update || ![style instancesRespondToSelector:NSSelectorFromString(@"_updateSegmentedControl")]) return;
        originalUpdateToolbar = (void (*)(id, SEL, id))method_setImplementation(update, (IMP)updateToolbar);

        Class controller = NSClassFromString(@"UITabBarController");
        SEL appear = NSSelectorFromString(@"viewDidAppear:");
        Method method = class_getInstanceMethod(controller, appear);
        if (!method) return;
        originalViewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(method);
        if (!class_addMethod(controller, appear, (IMP)viewDidAppear, method_getTypeEncoding(method))) {
            method_setImplementation(method, (IMP)viewDidAppear);
        }
    }
}
