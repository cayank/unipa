#import "../keychain/store.h"
#include <pwd.h>
#include <unistd.h>

static BOOL validComponent(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length] > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return ![value hasPrefix:@"."] && [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static UnipaKeychainStore *store(void) {
    static UnipaKeychainStore *keychain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            NSDictionary *configuration = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UnipaKeychain"];
            if (![configuration isKindOfClass:NSDictionary.class]) return;
            NSString *bundle = configuration[@"BundleIdentifier"], *instance = configuration[@"Instance"];
            if (!validComponent(bundle) || !validComponent(instance)) return;
            struct passwd user, *found = NULL;
            char buffer[16384];
            if (getpwuid_r(getuid(), &user, buffer, sizeof(buffer), &found) || !found) return;
            NSString *directory = [[NSString stringWithUTF8String:user.pw_dir]
                stringByAppendingPathComponent:@"Library/Application Support/unipa/Keychain"];
            directory = [directory stringByAppendingPathComponent:bundle];
            NSString *database = [directory stringByAppendingPathComponent:[instance stringByAppendingString:@".db"]];
            keychain = [[UnipaKeychainStore alloc] initWithDatabasePath:database];
        }
    });
    return keychain;
}

static OSStatus isolatedAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (result) *result = NULL;
    UnipaKeychainStore *keychain = store();
    return keychain ? [keychain add:attributes result:result] : errSecNotAvailable;
}

static OSStatus isolatedCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (result) *result = NULL;
    UnipaKeychainStore *keychain = store();
    return keychain ? [keychain copyMatching:query result:result] : errSecNotAvailable;
}

static OSStatus isolatedUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    UnipaKeychainStore *keychain = store();
    return keychain ? [keychain update:query attributes:attributes] : errSecNotAvailable;
}

static OSStatus isolatedDelete(CFDictionaryRef query) {
    UnipaKeychainStore *keychain = store();
    return keychain ? [keychain deleteMatching:query] : errSecNotAvailable;
}

static SecKeyRef isolatedCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    if (error) *error = NULL;
    UnipaKeychainStore *keychain = store();
    if (keychain) return [keychain createRandomKey:parameters error:error];
    if (error) *error = CFErrorCreate(NULL, kCFErrorDomainOSStatus, errSecNotAvailable, NULL);
    return NULL;
}

static OSStatus isolatedGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    if (publicKey) *publicKey = NULL;
    if (privateKey) *privateKey = NULL;
    CFErrorRef error = NULL;
    SecKeyRef generated = isolatedCreateRandomKey(parameters, &error);
    if (!generated) {
        OSStatus status = error ? (OSStatus)CFErrorGetCode(error) : errSecParam;
        if (error) CFRelease(error);
        return status;
    }
    if (publicKey) *publicKey = SecKeyCopyPublicKey(generated);
    if (privateKey) *privateKey = generated;
    else CFRelease(generated);
    return errSecSuccess;
}

__attribute__((used, section("__DATA,__interpose"))) static const struct {
    const void *replacement;
    const void *original;
} interpositions[] = {
    {(const void *)isolatedAdd, (const void *)SecItemAdd},
    {(const void *)isolatedCopyMatching, (const void *)SecItemCopyMatching},
    {(const void *)isolatedUpdate, (const void *)SecItemUpdate},
    {(const void *)isolatedDelete, (const void *)SecItemDelete},
    {(const void *)isolatedCreateRandomKey, (const void *)SecKeyCreateRandomKey},
    {(const void *)isolatedGeneratePair, (const void *)SecKeyGeneratePair},
};
