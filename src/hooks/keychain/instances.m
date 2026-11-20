#import "keychain/instances.h"
#include <pwd.h>
#include <unistd.h>

static NSString *const instanceKey = @"UnipaKeychainInstance";

static BOOL validBundleIdentifier(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return ![value hasPrefix:@"."] && [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

// Matches --keychain-instance after lowercasing: 1–64 letters, digits, dots, underscores, or hyphens.
BOOL unipaValidKeychainInstance(NSString *name) {
    if (![name isKindOfClass:NSString.class]) return NO;
    return [[NSPredicate predicateWithFormat:@"SELF MATCHES %@", @"[a-z0-9][a-z0-9._-]{0,63}"] evaluateWithObject:name];
}

static NSDictionary *configuration(void) {
    NSDictionary *keychain = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UnipaKeychain"];
    if (![keychain isKindOfClass:NSDictionary.class]) return nil;
    return validBundleIdentifier(keychain[@"BundleIdentifier"]) && unipaValidKeychainInstance(keychain[@"Instance"]) ? keychain : nil;
}

NSString *unipaKeychainDirectory(void) {
    static NSString *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *keychain = configuration();
        if (!keychain) return;
        // A sandboxed home directory is the app container, so read the real one.
        struct passwd user, *found = NULL;
        char buffer[16384];
        if (getpwuid_r(getuid(), &user, buffer, sizeof(buffer), &found) || !found) return;
        directory = [[[NSString stringWithUTF8String:user.pw_dir] stringByAppendingPathComponent:@"Library/Application Support/unipa/Keychain"]
            stringByAppendingPathComponent:keychain[@"BundleIdentifier"]];
    });
    return directory;
}

NSString *unipaSavedKeychainInstance(void) {
    if (!unipaKeychainDirectory()) return nil;
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:instanceKey];
    return unipaValidKeychainInstance(saved) ? saved : configuration()[@"Instance"];
}

void unipaSaveKeychainInstance(NSString *name) {
    if (!unipaKeychainDirectory() || !unipaValidKeychainInstance(name)) return;
    [NSUserDefaults.standardUserDefaults setObject:name forKey:instanceKey];
}

// Apps keep sign-ins in memory, so another instance applies the next time the app opens.
NSString *unipaActiveKeychainInstance(void) {
    static NSString *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = unipaSavedKeychainInstance();
    });
    return instance;
}

NSArray<NSString *> *unipaKeychainInstances(void) {
    NSString *directory = unipaKeychainDirectory();
    if (!directory) return @[];
    NSMutableSet *names = [NSMutableSet setWithObjects:unipaActiveKeychainInstance(), unipaSavedKeychainInstance(), nil];
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]) {
        NSString *name = file.stringByDeletingPathExtension;
        if ([file.pathExtension isEqualToString:@"db"] && unipaValidKeychainInstance(name)) [names addObject:name];
    }
    return [names.allObjects sortedArrayUsingSelector:@selector(compare:)];
}
