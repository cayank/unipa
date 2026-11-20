#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, UnipaAppearance) {
    UnipaAppearanceSystem,
    UnipaAppearanceLight,
    UnipaAppearanceDark,
};

UnipaAppearance unipaAppearance(void);
void unipaSetAppearance(UnipaAppearance appearance);
BOOL unipaKeepsOnTop(void);
void unipaSetKeepsOnTop(BOOL enabled);
BOOL unipaHidesTitleBar(void);
void unipaSetHidesTitleBar(BOOL hidden);
