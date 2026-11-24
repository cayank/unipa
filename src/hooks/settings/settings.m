#import "settings/settings.h"
#include <pwd.h>
#include <unistd.h>

static NSString *realHomeDirectory(void) {
    struct passwd user, *found = NULL;
    char buffer[16384];
    if (getpwuid_r(getuid(), &user, buffer, sizeof(buffer), &found) || !found) return NSHomeDirectory();
    return [NSString stringWithUTF8String:user.pw_dir];
}

static NSString *settingsPath(void) {
    NSString *bundleId = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
    NSString *directory = [[realHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/unipa/Settings"]
        stringByAppendingPathComponent:bundleId];
    return [directory stringByAppendingPathComponent:@"settings.plist"];
}

static NSDictionary *loadSettings(void) {
    return [NSDictionary dictionaryWithContentsOfFile:settingsPath()] ?: @{};
}

id unipaSettingValue(NSString *key) {
    return loadSettings()[key];
}

void unipaSetSettingValue(NSString *key, id value) {
    NSMutableDictionary *settings = [loadSettings() mutableCopy];
    settings[key] = value;
    [settings writeToFile:settingsPath() atomically:YES];
}

void unipaRemoveSetting(NSString *key) {
    NSMutableDictionary *settings = [loadSettings() mutableCopy];
    [settings removeObjectForKey:key];
    [settings writeToFile:settingsPath() atomically:YES];
}
