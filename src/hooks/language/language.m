#import <Foundation/Foundation.h>
#import "language/language.h"
#import "settings/settings.h"

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
    id code = unipaSettingValue(languageKey);
    return [unipaSupportedLanguages() containsObject:code] ? code : nil;
}

void unipaSaveLanguage(NSString *code) {
    if (![unipaSupportedLanguages() containsObject:code]) return;
    unipaSetSettingValue(languageKey, code);
    [NSUserDefaults.standardUserDefaults setObject:@[code] forKey:appleLanguagesKey];
}

void unipaUseSystemLanguage(void) {
    unipaRemoveSetting(languageKey);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:appleLanguagesKey];
}
