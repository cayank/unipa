#import <dlfcn.h>
#import "data/reset.h"
#import "settings/settings.h"

static NSString *const pendingResetKey = @"UnipaPendingReset";

static NSArray<NSString *> *keptPreferencePrefixes(void) {
    return @[@"Unipa", @"NSWindow Frame"];
}

static BOOL isSymbolicLink(NSString *path) {
    NSString *type = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL].fileType;
    return [type isEqualToString:NSFileTypeSymbolicLink];
}

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
        removeContents(library, [NSSet setWithObjects:@"Preferences", @"Caches", @"Application Scripts", nil]);
    }
}

void unipaScheduleReset(UnipaResetItems items) {
    unipaSetSettingValue(pendingResetKey, @(items));
}

__attribute__((constructor)) static void applyPendingReset(void) {
    @autoreleasepool {
        UnipaResetItems items = (UnipaResetItems)[unipaSettingValue(pendingResetKey) integerValue];
        if (!items) return;
        unipaRemoveSetting(pendingResetKey);
        NSString *container = NSHomeDirectory();
        if ([container containsString:@"/Library/Containers/"]) unipaResetAppData(container, NSBundle.mainBundle.bundleIdentifier, items);
    }
}
