#import <Foundation/Foundation.h>
#import <Security/Security.h>

@interface UnipaKeychainStore : NSObject
- (instancetype)initWithDatabasePath:(NSString *)database;
- (OSStatus)add:(CFDictionaryRef)attributes result:(CFTypeRef *)result;
- (OSStatus)copyMatching:(CFDictionaryRef)query result:(CFTypeRef *)result;
- (OSStatus)update:(CFDictionaryRef)query attributes:(CFDictionaryRef)attributes;
- (OSStatus)deleteMatching:(CFDictionaryRef)query;
- (SecKeyRef)createRandomKey:(CFDictionaryRef)parameters error:(CFErrorRef *)error CF_RETURNS_RETAINED;
@end
