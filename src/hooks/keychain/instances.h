#import <Foundation/Foundation.h>

NSString *unipaKeychainDirectory(void);
BOOL unipaValidKeychainInstance(NSString *name);
NSArray<NSString *> *unipaKeychainInstances(void);
NSString *unipaActiveKeychainInstance(void);
NSString *unipaSavedKeychainInstance(void);
void unipaSaveKeychainInstance(NSString *name);
