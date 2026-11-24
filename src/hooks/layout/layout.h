#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, UnipaLayout) {
    UnipaLayoutPhone,
    UnipaLayoutPad,
};

NSSize unipaLayoutSize(UnipaLayout layout);
UnipaLayout unipaActiveLayout(void);
void unipaSetActiveLayout(UnipaLayout layout);
UnipaLayout unipaSavedLayout(void);
void unipaSaveLayout(UnipaLayout layout);
NSSize unipaPreferredWindowSize(void);
void unipaRefreshActiveLayout(void);
