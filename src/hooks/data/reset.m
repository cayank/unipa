#import <dlfcn.h>
#import "data/reset.h"

static NSString *const pendingResetKey = @"UnipaPendingReset";

// unipa's own settings and the window position survive a reset.
static NSArray<NSString *> *keptPreferencePrefixes(void) {
    return @[@"Unipa", @"NSWindow Frame"];
}

static BOOL isSymbolicLink(NSString *path) {
    // attributesOfItemAtPath: describes the link itself instead of its target.
    NSString *type = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL].fileType;
    return [type isEqualToString:NSFileTypeSymbolicLink];
}

// Sandbox containers link to the user's real folders, so links are never followed or removed.
static void removeContents(NSString *folder, NSSet<NSString *> *kept) {
    if (isSymbolicLink(folder)) return;
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:NULL]) {
        NSString *path = [folder stringByAppendingPathComponent:name];
        if ([kept containsObject:name] || isSymbolicLink(path)) continue;
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    }
}

static void resetPreferences(NSString *container, NSString *domain) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *current = [defaults persistentDomainForName:domain];
    NSMutableDictionary *kept = [NSMutableDictionary dictionary];
    for (NSString *key in current) {
        for (NSString *prefix in keptPreferencePrefixes()) {
            if ([key hasPrefix:prefix]) kept[key] = current[key];
        }
    }
    [defaults setPersistentDomain:kept forName:domain];
    // SDKs such as Firebase keep their own preference files next to the app's.
    NSString *folder = [container stringByAppendingPathComponent:@"Library/Preferences"];
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:NULL]) {
        NSString *suite = file.stringByDeletingPathExtension;
        if (![file.pathExtension isEqualToString:@"plist"] || [suite isEqualToString:domain] || [suite hasPrefix:@"com.apple."]) continue;
        [defaults removePersistentDomainForName:suite];
    }
    [defaults synchronize];
}

void unipaResetAppData(NSString *container, NSString *domain, UnipaResetItems items) {
    if (!container.length || !domain.length) return;
    if (items & UnipaResetKeychain) {
        // Isolated Keychain support is compiled in only for apps that use it.
        BOOL (*clear)(void) = (BOOL (*)(void))dlsym(RTLD_SELF, "unipaClearKeychain");
        if (clear) clear();
    }
    NSString *library = [container stringByAppendingPathComponent:@"Library"];
    if (items & UnipaResetPreferences) resetPreferences(container, domain);
    if (items & UnipaResetCaches) {
        removeContents([library stringByAppendingPathComponent:@"Caches"], [NSSet set]);
        removeContents([container stringByAppendingPathComponent:@"tmp"], [NSSet set]);
    }
    if (items & UnipaResetFiles) {
        removeContents([container stringByAppendingPathComponent:@"Documents"], [NSSet set]);
        // Preferences and caches have their own options, and Application Scripts belongs to the system.
        removeContents(library, [NSSet setWithObjects:@"Preferences", @"Caches", @"Application Scripts", nil]);
    }
}

void unipaScheduleReset(UnipaResetItems items) {
    [NSUserDefaults.standardUserDefaults setInteger:(NSInteger)items forKey:pendingResetKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

// Apps write their preferences back while quitting, so the reset runs at the next launch, before the app's code.
__attribute__((constructor)) static void applyPendingReset(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        UnipaResetItems items = (UnipaResetItems)[defaults integerForKey:pendingResetKey];
        if (!items) return;
        [defaults removeObjectForKey:pendingResetKey];
        // A sandboxed app's home directory is its container; outside a container this would be the user's home.
        NSString *container = NSHomeDirectory();
        if ([container containsString:@"/Library/Containers/"]) unipaResetAppData(container, NSBundle.mainBundle.bundleIdentifier, items);
    }
}
