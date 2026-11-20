#import <Foundation/Foundation.h>

typedef NS_OPTIONS(NSUInteger, UnipaResetItems) {
    UnipaResetPreferences = 1 << 0,
    UnipaResetCaches = 1 << 1,
    UnipaResetFiles = 1 << 2,
    UnipaResetKeychain = 1 << 3,
};

void unipaResetAppData(NSString *container, NSString *domain, UnipaResetItems items);
void unipaScheduleReset(UnipaResetItems items);
