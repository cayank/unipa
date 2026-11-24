#import "layout/layout.h"
#import "settings/settings.h"

static NSString *const layoutKey = @"UnipaLayout";

static NSSize profileSize(id profile) {
    if (![profile isKindOfClass:NSDictionary.class]) return NSZeroSize;
    id width = profile[@"width"];
    id height = profile[@"height"];
    if (![width isKindOfClass:NSNumber.class] || ![height isKindOfClass:NSNumber.class]) return NSZeroSize;
    double w = [width doubleValue];
    double h = [height doubleValue];
    if (!isfinite(w) || !isfinite(h) || w <= 0 || h <= 0 || w > 16384 || h > 16384) return NSZeroSize;
    return NSMakeSize(w, h);
}

NSSize unipaLayoutSize(UnipaLayout layout) {
    static NSSize phone;
    static NSSize pad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id profile = NSBundle.mainBundle.infoDictionary[@"UnipaDisplay"];
        phone = profileSize(profile);
        if (phone.width > 0) pad = profileSize(profile[@"ipad"]);
    });
    return layout == UnipaLayoutPad ? pad : phone;
}

UnipaLayout unipaSavedLayout(void) {
    id saved = unipaSettingValue(layoutKey);
    return [saved isEqual:@"ipad"] ? UnipaLayoutPad : UnipaLayoutPhone;
}

void unipaSaveLayout(UnipaLayout layout) {
    unipaSetSettingValue(layoutKey, layout == UnipaLayoutPad ? @"ipad" : @"iphone");
}

static UnipaLayout activeLayout;
static BOOL activeLayoutOverridden;

static UnipaLayout layoutFromDefaults(void) {
    return unipaSavedLayout() == UnipaLayoutPad && unipaLayoutSize(UnipaLayoutPad).width > 0 ? UnipaLayoutPad : UnipaLayoutPhone;
}

UnipaLayout unipaActiveLayout(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        activeLayout = layoutFromDefaults();
    });
    return activeLayout;
}

void unipaSetActiveLayout(UnipaLayout layout) {
    unipaActiveLayout();
    if (unipaLayoutSize(layout).width <= 0) return;
    activeLayout = layout;
    activeLayoutOverridden = YES;
}

void unipaRefreshActiveLayout(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!activeLayoutOverridden) activeLayout = layoutFromDefaults();
    });
}

NSSize unipaPreferredWindowSize(void) {
    return unipaLayoutSize(unipaActiveLayout());
}
