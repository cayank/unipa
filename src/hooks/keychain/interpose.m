#import "keychain/store.h"
#import "keychain/instances.h"

static UnipaKeychainStore *store(void) {
    static UnipaKeychainStore *keychain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            NSString *directory = unipaKeychainDirectory(), *instance = unipaActiveKeychainInstance();
            if (!directory || !instance) return;
            keychain = [[UnipaKeychainStore alloc] initWithDatabasePath:[directory stringByAppendingPathComponent:[instance stringByAppendingString:@".db"]]];
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

// The interposed SecItem functions skip unipa's own image, so Device Info reads the store through this.
OSStatus unipaKeychainCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    return isolatedCopyMatching(query, result);
}

// Called from the unipa menu for the instance in use. Items are deleted per class, as SecItemDelete requires.
BOOL unipaClearKeychain(void) {
    UnipaKeychainStore *keychain = store();
    if (!keychain) return NO;
    NSArray *classes = @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword,
                         (__bridge id)kSecClassKey, (__bridge id)kSecClassCertificate];
    for (id itemClass in classes) {
        OSStatus status = [keychain deleteMatching:(__bridge CFDictionaryRef)@{(__bridge id)kSecClass: itemClass}];
        if (status != errSecSuccess && status != errSecItemNotFound) return NO;
    }
    return YES;
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
