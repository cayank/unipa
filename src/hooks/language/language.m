#import <Foundation/Foundation.h>
#import "language/language.h"

static NSString *const languageKey = @"UnipaLanguage";
static NSString *const appleLanguagesKey = @"AppleLanguages";

NSArray<NSString *> *unipaSupportedLanguages(void) {
    NSMutableArray *languages = [NSMutableArray array];
    for (NSString *code in NSBundle.mainBundle.localizations) {
        if (![code isEqualToString:@"Base"]) [languages addObject:code];
    }
    return [languages sortedArrayUsingSelector:@selector(compare:)];
}

NSString *unipaSavedLanguage(void) {
    NSString *code = [NSUserDefaults.standardUserDefaults stringForKey:languageKey];
    return [unipaSupportedLanguages() containsObject:code] ? code : nil;
}

void unipaSaveLanguage(NSString *code) {
    if (![unipaSupportedLanguages() containsObject:code]) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:code forKey:languageKey];
    [defaults setObject:@[code] forKey:appleLanguagesKey];
}

void unipaUseSystemLanguage(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:languageKey];
    [defaults removeObjectForKey:appleLanguagesKey];
}
