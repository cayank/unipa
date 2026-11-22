#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "data/reset.h"
#import "device/info.h"
#import "keychain/instances.h"
#import "language/language.h"
#import "layout/layout.h"
#import "location/location.h"
#import "window/geometry.h"
#import "window/style.h"

static NSString *const menuIdentifier = @"unipa.menu";
static NSString *const keychainInstanceAction = @"keychain.instance.";
static NSString *const languageAction = @"language.";
static const NSInteger menuStateOn = 1;
static const NSUInteger menuAttributesDisabled = 1;
static const NSUInteger menuOptionsDisplayInline = 1;
static void (*originalBuildMenu)(id, SEL, id);

typedef BOOL (*UnipaKeychainReset)(void);

// Isolated Keychain support is compiled in only for apps that use it.
static UnipaKeychainReset keychainReset(void) {
    return (UnipaKeychainReset)dlsym(RTLD_SELF, "unipaClearKeychain");
}

static NSString *applicationName(void) {
    return NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: NSProcessInfo.processInfo.processName;
}

static NSString *layoutTitle(UnipaLayout layout) {
    NSString *name = layout == UnipaLayoutPad ? @"iPad" : @"iPhone";
    NSSize size = unipaLayoutSize(layout);
    return size.width > 0 ? [NSString stringWithFormat:@"%@ (%.0f × %.0f)", name, size.width, size.height] : name;
}

static NSString *coordinateText(UnipaCoordinate coordinate) {
    return [NSString stringWithFormat:@"%.5f, %.5f", coordinate.latitude, coordinate.longitude];
}

static void showMessage(NSString *title, NSString *message) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = message;
    [alert runModal];
}

static id makeCommand(NSString *title, NSString *action, BOOL on, BOOL enabled) {
    SEL create = NSSelectorFromString(@"commandWithTitle:image:action:propertyList:");
    id command = ((id (*)(id, SEL, NSString *, id, SEL, id))objc_msgSend)(
        NSClassFromString(@"UICommand"), create, title, nil, NSSelectorFromString(@"unipaMenuCommand:"), action);
    if (on) [command setValue:@(menuStateOn) forKey:@"state"];
    if (!enabled) [command setValue:@(menuAttributesDisabled) forKey:@"attributes"];
    return command;
}

static id makeMenu(NSString *title, NSString *identifier, NSUInteger options, NSArray *children) {
    SEL create = NSSelectorFromString(@"menuWithTitle:image:identifier:options:children:");
    return ((id (*)(id, SEL, NSString *, id, NSString *, NSUInteger, NSArray *))objc_msgSend)(
        NSClassFromString(@"UIMenu"), create, title, nil, identifier, options, children);
}

static id layoutMenu(void) {
    return makeMenu(@"Layout", @"unipa.menu.layout", 0, @[
        makeCommand(layoutTitle(UnipaLayoutPhone), @"layout.iphone", unipaSavedLayout() == UnipaLayoutPhone, YES),
        makeCommand(layoutTitle(UnipaLayoutPad), @"layout.ipad", unipaSavedLayout() == UnipaLayoutPad, unipaLayoutSize(UnipaLayoutPad).width > 0),
    ]);
}

static NSString *languageTitle(NSString *code) {
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:code];
    NSString *name = [locale localizedStringForLocaleIdentifier:code];
    return name.length ? [name capitalizedStringWithLocale:locale] : code;
}

static id languageMenu(void) {
    NSArray<NSString *> *languages = unipaSupportedLanguages();
    if (!languages.count) return nil;
    NSString *saved = unipaSavedLanguage();
    NSMutableArray *items = [NSMutableArray arrayWithObject:makeCommand(@"System", @"language.system", saved == nil, YES)];
    for (NSString *code in languages) {
        [items addObject:makeCommand(languageTitle(code), [languageAction stringByAppendingString:code], [code isEqualToString:saved], YES)];
    }
    return makeMenu(@"Language", @"unipa.menu.language", 0, items);
}

static id appearanceMenu(void) {
    UnipaAppearance appearance = unipaAppearance();
    return makeMenu(@"Appearance", @"unipa.menu.appearance", 0, @[
        makeCommand(@"System", @"appearance.system", appearance == UnipaAppearanceSystem, YES),
        makeCommand(@"Light", @"appearance.light", appearance == UnipaAppearanceLight, YES),
        makeCommand(@"Dark", @"appearance.dark", appearance == UnipaAppearanceDark, YES),
    ]);
}

static id locationMenu(void) {
    UnipaCoordinate coordinate;
    BOOL simulated = unipaSimulatedCoordinate(&coordinate);
    BOOL available = unipaLocationAvailable();
    NSMutableArray *items = [NSMutableArray arrayWithObject:makeCommand(@"Real Location", @"location.real", !simulated, available)];
    // UIKit rejects menus with two identical commands, so the current location has its own action.
    if (simulated) [items addObject:makeCommand(coordinateText(coordinate), @"location.current", YES, available)];
    [items addObject:makeCommand(@"Simulate Location…", @"location.set", NO, available)];
    return makeMenu(@"Location", @"unipa.menu.location", 0, items);
}

static id keychainMenu(void) {
    if (!unipaKeychainDirectory()) {
        return makeMenu(@"Keychain", @"unipa.menu.keychain", 0, @[makeCommand(@"Native Keychain", @"keychain.native", YES, NO)]);
    }
    NSString *active = unipaActiveKeychainInstance(), *saved = unipaSavedKeychainInstance();
    NSMutableArray *instances = [NSMutableArray array];
    for (NSString *name in unipaKeychainInstances()) {
        // After choosing Later, the instance still in use stays visible until the app reopens.
        NSString *title = [name isEqualToString:active] && ![name isEqualToString:saved] ? [name stringByAppendingString:@" (in use)"] : name;
        [instances addObject:makeCommand(title, [keychainInstanceAction stringByAppendingString:name], [name isEqualToString:saved], YES)];
    }
    return makeMenu(@"Keychain", @"unipa.menu.keychain", 0, @[
        makeMenu(@"", @"unipa.menu.keychain.instances", menuOptionsDisplayInline, instances),
        makeMenu(@"", @"unipa.menu.keychain.actions", menuOptionsDisplayInline, @[
            makeCommand(@"New Instance…", @"keychain.new", NO, YES),
            makeCommand([NSString stringWithFormat:@"Clear “%@”…", active], @"keychain.clear", NO, keychainReset() != NULL),
        ]),
    ]);
}

static id unipaMenu(void) {
    // The Language submenu appears only when the app ships more than its base localization.
    NSMutableArray *display = [NSMutableArray arrayWithObjects:layoutMenu(), appearanceMenu(), nil];
    id language = languageMenu();
    if (language) [display addObject:language];
    [display addObject:makeCommand(@"Keep on Top", @"window.top", unipaKeepsOnTop(), YES)];
    [display addObject:makeCommand(@"Hide Title Bar", @"window.titlebar", unipaHidesTitleBar(), YES)];

    // About comes first, like an app menu; then appearance, identity and data, tools, and the reset.
    return makeMenu(@"unipa", menuIdentifier, 0, @[
        makeMenu(@"", @"unipa.menu.about", menuOptionsDisplayInline, @[makeCommand(@"About unipa", @"about", NO, YES)]),
        makeMenu(@"", @"unipa.menu.display", menuOptionsDisplayInline, display),
        makeMenu(@"", @"unipa.menu.identity", menuOptionsDisplayInline, @[locationMenu(), keychainMenu()]),
        makeMenu(@"", @"unipa.menu.tools", menuOptionsDisplayInline, @[
            makeCommand(@"Device Info", @"data.device", NO, YES),
            makeCommand(@"Show App Data in Finder", @"data.show", NO, YES),
        ]),
        // Destructive commands stay apart from the others.
        makeMenu(@"", @"unipa.menu.reset", menuOptionsDisplayInline, @[makeCommand(@"Reset App…", @"data.reset", NO, YES)]),
    ]);
}

static void buildMenu(id application, SEL selector, id builder) {
    originalBuildMenu(application, selector, builder);
    id mainSystem = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"UIMenuSystem"), NSSelectorFromString(@"mainSystem"));
    if ([builder valueForKey:@"system"] != mainSystem) return;
    SEL find = NSSelectorFromString(@"menuForIdentifier:");
    if (((id (*)(id, SEL, NSString *))objc_msgSend)(builder, find, menuIdentifier)) {
        ((void (*)(id, SEL, NSString *, id))objc_msgSend)(builder, NSSelectorFromString(@"replaceMenuForIdentifier:withMenu:"), menuIdentifier, unipaMenu());
        return;
    }
    // Apps may remove standard menus, so fall back to the Window menu.
    for (NSString *anchor in @[@"com.apple.menu.help", @"com.apple.menu.window"]) {
        if (!((id (*)(id, SEL, NSString *))objc_msgSend)(builder, find, anchor)) continue;
        ((void (*)(id, SEL, id, NSString *))objc_msgSend)(builder, NSSelectorFromString(@"insertSiblingMenu:afterMenuForIdentifier:"), unipaMenu(), anchor);
        return;
    }
}

static void rebuildMenu(void) {
    id mainSystem = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"UIMenuSystem"), NSSelectorFromString(@"mainSystem"));
    ((void (*)(id, SEL))objc_msgSend)(mainSystem, NSSelectorFromString(@"setNeedsRebuild"));
}

// iOS apps save their state on entering the background, since the system may stop them at any time after that.
// Catalyst then waits up to 30 seconds for background tasks, so unipa exits once the app has had a moment to save.
// The main queue is blocked while AppKit waits to terminate, so the timer runs on a background queue.
// beforeExit runs after the app has saved its state, so data it writes while quitting can still be removed.
static void quitApplication(dispatch_block_t beforeExit) {
    [NSNotificationCenter.defaultCenter addObserverForName:@"UIApplicationDidEnterBackgroundNotification" object:nil
                                                     queue:nil usingBlock:^(__unused NSNotification *notification) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (beforeExit) beforeExit();
            [NSUserDefaults.standardUserDefaults synchronize];
            exit(0);
        });
    }];
    [NSApp terminate:nil];
}

static void selectLayout(UnipaLayout layout) {
    if (unipaLayoutSize(layout).width <= 0) return;
    unipaSaveLayout(layout);
    if (layout == unipaActiveLayout()) return;

    // Catalyst apps run one instance and the sandbox blocks helpers, so the app cannot reopen itself.
    // Switching now resizes the running scene, but views sized at launch may keep the old layout.
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Switch to the %@ layout?", layout == UnipaLayoutPad ? @"iPad" : @"iPhone"];
    alert.informativeText = [NSString stringWithFormat:@"Quit and reopen %@ for the best result, or switch now. "
                             "Some screens may look wrong until the app is reopened.", applicationName()];
    [alert addButtonWithTitle:@"Quit"];
    [alert addButtonWithTitle:@"Switch Now"];
    [alert addButtonWithTitle:@"Later"];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        quitApplication(nil);
    } else if (response == NSAlertSecondButtonReturn) {
        unipaSetActiveLayout(layout);
        unipaScheduleWindowLayout();
    }
}

static NSString *askForText(NSString *title, NSString *message, NSString *value, NSString *placeholder, NSString *button) {
    NSTextField *field = [NSTextField textFieldWithString:value];
    field.placeholderString = placeholder;
    field.frame = NSMakeRect(0, 0, 260, 24);
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = message;
    alert.accessoryView = field;
    [alert addButtonWithTitle:button];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.initialFirstResponder = field;
    return [alert runModal] == NSAlertFirstButtonReturn ? field.stringValue : nil;
}

static void chooseLocation(void) {
    UnipaCoordinate current;
    NSString *text = askForText(@"Simulate Location", [NSString stringWithFormat:@"Enter the latitude and longitude %@ should see.", applicationName()],
                                unipaSimulatedCoordinate(&current) ? coordinateText(current) : @"", @"41.0082, 28.9784", @"Simulate");
    if (!text) return;
    UnipaCoordinate coordinate;
    if (!unipaParseCoordinate(text, &coordinate)) {
        showMessage(@"Invalid location", @"Enter a latitude and longitude, for example 41.0082, 28.9784.");
        return;
    }
    unipaSimulateLocation(coordinate);
}

static NSButton *checkbox(NSString *title, BOOL on, BOOL enabled) {
    NSButton *button = [NSButton checkboxWithTitle:title target:nil action:nil];
    button.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    button.enabled = enabled;
    return button;
}

static void resetApp(void) {
    // A sandboxed app's home directory is its container; outside a container this would be the user's home.
    NSString *container = NSHomeDirectory();
    if (![container containsString:@"/Library/Containers/"]) return;
    UnipaKeychainReset reset = keychainReset();
    NSString *instance = unipaActiveKeychainInstance();
    NSButton *keychain = checkbox(reset ? [NSString stringWithFormat:@"Keychain (“%@”)", instance] : @"Keychain (needs isolated storage)", reset != NULL, reset != NULL);
    NSButton *preferences = checkbox(@"Preferences, including saved addresses and device IDs", YES, YES);
    NSButton *caches = checkbox(@"Caches", YES, YES);
    // Everything is selected by default: SDKs restore IDs from their own files, so a partial reset can look like no reset.
    NSButton *files = checkbox(@"All app files, such as documents and databases", YES, YES);
    NSStackView *options = [NSStackView stackViewWithViews:@[keychain, preferences, caches, files]];
    options.orientation = NSUserInterfaceLayoutOrientationVertical;
    options.alignment = NSLayoutAttributeLeading;
    options.frame = NSMakeRect(0, 0, 380, 96);

    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = [NSString stringWithFormat:@"Reset %@?", applicationName()];
    alert.informativeText = @"The app quits, and the selected data is deleted when it opens again. unipa settings are kept.";
    alert.accessoryView = options;
    [alert addButtonWithTitle:@"Reset and Quit"].hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    UnipaResetItems items = (keychain.state == NSControlStateValueOn ? UnipaResetKeychain : 0) |
                            (preferences.state == NSControlStateValueOn ? UnipaResetPreferences : 0) |
                            (caches.state == NSControlStateValueOn ? UnipaResetCaches : 0) |
                            (files.state == NSControlStateValueOn ? UnipaResetFiles : 0);
    if (!items) return;
    unipaScheduleReset(items);
    quitApplication(nil);
}

static void showApplicationData(void) {
    // A sandboxed app's home directory is its container.
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:NSHomeDirectory()]]];
}

static void showDeviceInfo(void) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 480, 300)];
    NSTextView *text = [[NSTextView alloc] initWithFrame:scroll.bounds];
    text.string = unipaDeviceReport();
    text.editable = NO;
    text.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    text.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = text;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Device Info";
    alert.informativeText = @"Keychain values can include passwords and sign-in tokens.";
    alert.accessoryView = scroll;
    [alert addButtonWithTitle:@"Copy"];
    [alert addButtonWithTitle:@"Close"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text.string forType:NSPasteboardTypeString];
}

static void selectKeychainInstance(NSString *name) {
    if (!unipaKeychainDirectory() || !unipaValidKeychainInstance(name)) return;
    unipaSaveKeychainInstance(name);

    if ([name isEqualToString:unipaActiveKeychainInstance()]) return;
    
    // The app keeps sign-ins in memory, so it reads the other Keychain only after reopening.
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Switch to the “%@” Keychain?", name];
    alert.informativeText = [NSString stringWithFormat:@"%@ will use it the next time it opens. Preferences and files stay shared between Keychains.", applicationName()];
    [alert addButtonWithTitle:@"Quit"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] == NSAlertFirstButtonReturn) quitApplication(nil);
}

static void createKeychainInstance(void) {
    NSString *text = askForText(@"New Keychain Instance", @"Use 1–64 letters, digits, dots, underscores, or hyphens.", @"", @"second", @"Create");
    if (!text) return;
    NSString *name = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    if (!unipaValidKeychainInstance(name)) {
        showMessage(@"Invalid instance name", @"Use 1–64 letters, digits, dots, underscores, or hyphens, starting with a letter or digit.");
        return;
    }
    selectKeychainInstance(name);
}

static void clearKeychain(void) {
    UnipaKeychainReset reset = keychainReset();
    if (!reset) return;
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = [NSString stringWithFormat:@"Clear the “%@” Keychain for %@?", unipaActiveKeychainInstance(), applicationName()];
    alert.informativeText = @"Saved passwords and sign-ins will be deleted, so you will need to sign in again. The app quits afterwards.";
    [alert addButtonWithTitle:@"Clear and Quit"].hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    // The app keeps sign-ins in memory, so it quits to stop using the deleted items.
    if (reset()) quitApplication(^{ reset(); });
    else showMessage(@"Could not clear the Keychain", @"Some Keychain items could not be deleted.");
}

static void showAbout(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *keychain = unipaActiveKeychainInstance();
    UnipaCoordinate coordinate;
    NSArray *lines = @[
        [NSString stringWithFormat:@"App: %@ %@", applicationName(), info[@"CFBundleShortVersionString"] ?: @""],
        [NSString stringWithFormat:@"Bundle ID: %@", NSBundle.mainBundle.bundleIdentifier],
        [NSString stringWithFormat:@"Layout: %@", layoutTitle(unipaActiveLayout())],
        [NSString stringWithFormat:@"Keychain: %@", keychain ? [NSString stringWithFormat:@"Isolated (%@)", keychain] : @"Native"],
        [NSString stringWithFormat:@"Location: %@", unipaSimulatedCoordinate(&coordinate) ? coordinateText(coordinate) : @"Real"],
        [NSString stringWithFormat:@"Language: %@", unipaSavedLanguage() ? languageTitle(unipaSavedLanguage()) : @"System"],
    ];
    showMessage([NSString stringWithFormat:@"unipa %@", info[@"UnipaVersion"] ?: @""], [lines componentsJoinedByString:@"\n"]);
}

// Foundation reads the language at launch, so a change applies the next time the app opens.
static void selectLanguage(NSString *code) {
    NSString *current = unipaSavedLanguage();
    if ((code == nil && current == nil) || [code isEqualToString:current]) return;
    if (code) unipaSaveLanguage(code);
    else unipaUseSystemLanguage();

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Change language?";
    alert.informativeText = [NSString stringWithFormat:@"%@ will use the new language the next time it opens.", applicationName()];
    [alert addButtonWithTitle:@"Quit"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] == NSAlertFirstButtonReturn) quitApplication(nil);
}

static NSDictionary<NSString *, dispatch_block_t> *menuActions(void) {
    static NSDictionary *actions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        actions = @{
            @"layout.iphone": ^{ selectLayout(UnipaLayoutPhone); },
            @"layout.ipad": ^{ selectLayout(UnipaLayoutPad); },
            @"appearance.system": ^{ unipaSetAppearance(UnipaAppearanceSystem); },
            @"appearance.light": ^{ unipaSetAppearance(UnipaAppearanceLight); },
            @"appearance.dark": ^{ unipaSetAppearance(UnipaAppearanceDark); },
            @"language.system": ^{ selectLanguage(nil); },
            @"location.real": ^{ unipaUseRealLocation(); },
            @"location.current": ^{ chooseLocation(); },
            @"location.set": ^{ chooseLocation(); },
            @"window.top": ^{ unipaSetKeepsOnTop(!unipaKeepsOnTop()); },
            @"window.titlebar": ^{ unipaSetHidesTitleBar(!unipaHidesTitleBar()); },
            @"data.show": ^{ showApplicationData(); },
            @"data.reset": ^{ resetApp(); },
            @"data.device": ^{ showDeviceInfo(); },
            @"keychain.new": ^{ createKeychainInstance(); },
            @"keychain.clear": ^{ clearKeychain(); },
            @"about": ^{ showAbout(); },
        };
    });
    return actions;
}

static void performCommand(__unused id application, __unused SEL selector, id command) {
    NSString *name = [command valueForKey:@"propertyList"];
    if (![name isKindOfClass:NSString.class]) return;
    dispatch_block_t action = menuActions()[name];
    if (action) action();
    else if ([name hasPrefix:keychainInstanceAction]) selectKeychainInstance([name substringFromIndex:keychainInstanceAction.length]);
    else if ([name hasPrefix:languageAction]) selectLanguage([name substringFromIndex:languageAction.length]);
    else return;
    rebuildMenu();
}

__attribute__((constructor)) static void installMenu(void) {
    @autoreleasepool {
        if (unipaPreferredWindowSize().width <= 0) return;
        Class application = NSClassFromString(@"UIApplication");
        SEL build = NSSelectorFromString(@"buildMenuWithBuilder:");
        Method method = class_getInstanceMethod(application, build);
        if (!method) return;
        
        // UIApplication passes the builder on to the app delegate, so unipa adds its menu last.
        originalBuildMenu = (void (*)(id, SEL, id))method_getImplementation(method);
        if (!class_addMethod(application, build, (IMP)buildMenu, method_getTypeEncoding(method))) {
            method_setImplementation(method, (IMP)buildMenu);
        }
        class_addMethod(application, NSSelectorFromString(@"unipaMenuCommand:"), (IMP)performCommand, "v@:@");
    }
}
