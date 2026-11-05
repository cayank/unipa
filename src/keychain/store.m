#import "store.h"
#include <sqlite3.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static NSString * const itemID = @"UnipaItemID";
static const char referencePrefix[] = "UNIPAKC1";

static NSArray *primaryAttributes(id itemClass) {
    if ([itemClass isEqual:(__bridge id)kSecClassGenericPassword]) {
        return @[(__bridge id)kSecAttrAccessGroup, (__bridge id)kSecAttrAccount, (__bridge id)kSecAttrService];
    }
    if ([itemClass isEqual:(__bridge id)kSecClassInternetPassword]) {
        return @[(__bridge id)kSecAttrAccessGroup, (__bridge id)kSecAttrAccount, (__bridge id)kSecAttrServer,
                 (__bridge id)kSecAttrSecurityDomain, (__bridge id)kSecAttrProtocol, (__bridge id)kSecAttrAuthenticationType,
                 (__bridge id)kSecAttrPort, (__bridge id)kSecAttrPath];
    }
    if ([itemClass isEqual:(__bridge id)kSecClassKey]) {
        return @[(__bridge id)kSecAttrAccessGroup, (__bridge id)kSecAttrApplicationLabel,
                 (__bridge id)kSecAttrApplicationTag, (__bridge id)kSecAttrKeyClass, (__bridge id)kSecAttrKeyType,
                 (__bridge id)kSecAttrKeySizeInBits, (__bridge id)kSecAttrEffectiveKeySize];
    }
    if ([itemClass isEqual:(__bridge id)kSecClassCertificate]) {
        return @[(__bridge id)kSecAttrAccessGroup, (__bridge id)kSecAttrIssuer, (__bridge id)kSecAttrSerialNumber];
    }
    return nil;
}

static NSSet *returnKeys(void) {
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithArray:@[(__bridge id)kSecReturnData, (__bridge id)kSecReturnAttributes,
                                (__bridge id)kSecReturnRef, (__bridge id)kSecReturnPersistentRef]];
    });
    return keys;
}

static NSSet *optionKeys(void) {
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [returnKeys() setByAddingObjectsFromArray:@[(__bridge id)kSecMatchLimit, (__bridge id)kSecUseAuthenticationUI,
                                                      (__bridge id)kSecUseOperationPrompt, (__bridge id)kSecUseDataProtectionKeychain]];
    });
    return keys;
}

static NSSet *attributeKeys(void) {
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithArray:@[
            (__bridge id)kSecClass, (__bridge id)kSecAttrAccessGroup, (__bridge id)kSecAttrAccount,
            (__bridge id)kSecAttrService, (__bridge id)kSecAttrServer, (__bridge id)kSecAttrSecurityDomain,
            (__bridge id)kSecAttrProtocol, (__bridge id)kSecAttrAuthenticationType, (__bridge id)kSecAttrPort,
            (__bridge id)kSecAttrPath, (__bridge id)kSecAttrAccessible, (__bridge id)kSecAttrSynchronizable,
            (__bridge id)kSecAttrLabel, (__bridge id)kSecAttrDescription, (__bridge id)kSecAttrComment,
            (__bridge id)kSecAttrCreator, (__bridge id)kSecAttrType, (__bridge id)kSecAttrIsInvisible,
            (__bridge id)kSecAttrIsNegative, (__bridge id)kSecAttrGeneric, (__bridge id)kSecValueData,
            (__bridge id)kSecAttrApplicationLabel, (__bridge id)kSecAttrApplicationTag, (__bridge id)kSecAttrKeyClass,
            (__bridge id)kSecAttrKeyType, (__bridge id)kSecAttrKeySizeInBits, (__bridge id)kSecAttrEffectiveKeySize,
            (__bridge id)kSecAttrIsPermanent, (__bridge id)kSecAttrCanEncrypt, (__bridge id)kSecAttrCanDecrypt,
            (__bridge id)kSecAttrCanDerive, (__bridge id)kSecAttrCanSign, (__bridge id)kSecAttrCanVerify,
            (__bridge id)kSecAttrCanWrap, (__bridge id)kSecAttrCanUnwrap,
            (__bridge id)kSecAttrCertificateType, (__bridge id)kSecAttrCertificateEncoding,
            (__bridge id)kSecAttrSubject, (__bridge id)kSecAttrIssuer, (__bridge id)kSecAttrSerialNumber,
            (__bridge id)kSecAttrSubjectKeyID, (__bridge id)kSecAttrPublicKeyHash,
        ]];
    });
    return keys;
}

static BOOL flag(NSDictionary *dictionary, CFStringRef key) {
    return [dictionary[(__bridge id)key] boolValue];
}

static NSSet *stringAttributes(void) {
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithArray:@[
            (__bridge id)kSecAttrAccount, (__bridge id)kSecAttrService, (__bridge id)kSecAttrAccessGroup,
            (__bridge id)kSecAttrServer, (__bridge id)kSecAttrSecurityDomain, (__bridge id)kSecAttrPath,
            (__bridge id)kSecAttrProtocol, (__bridge id)kSecAttrAuthenticationType, (__bridge id)kSecAttrAccessible,
            (__bridge id)kSecAttrLabel, (__bridge id)kSecAttrDescription, (__bridge id)kSecAttrComment,
            (__bridge id)kSecAttrKeyType, (__bridge id)kSecAttrKeyClass,
        ]];
    });
    return keys;
}

static NSSet *dataAttributes(void) {
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithArray:@[
            (__bridge id)kSecValueData, (__bridge id)kSecAttrGeneric, (__bridge id)kSecAttrApplicationTag,
            (__bridge id)kSecAttrApplicationLabel, (__bridge id)kSecAttrSubject, (__bridge id)kSecAttrIssuer,
            (__bridge id)kSecAttrSerialNumber, (__bridge id)kSecAttrSubjectKeyID, (__bridge id)kSecAttrPublicKeyHash,
        ]];
    });
    return keys;
}

static OSStatus validate(NSDictionary *dictionary, BOOL query) {
    id itemClass = dictionary[(__bridge id)kSecClass];
    if (itemClass && !primaryAttributes(itemClass)) return errSecUnimplemented;
    if (!query && !itemClass) return errSecParam;
    for (id key in dictionary) {
        if (![key isKindOfClass:NSString.class]) return errSecParam;
        if ([stringAttributes() containsObject:key] && ![dictionary[key] isKindOfClass:NSString.class]) return errSecParam;
        if ([dataAttributes() containsObject:key] && ![dictionary[key] isKindOfClass:NSData.class]) return errSecParam;
        if ([attributeKeys() containsObject:key]) continue;
        if ([optionKeys() containsObject:key]) continue;
        if (query && [key isEqual:(__bridge id)kSecValuePersistentRef]) continue;
        if (!query && [key isEqual:(__bridge id)kSecValueRef]) continue;
        return errSecUnimplemented;
    }
    id sync = dictionary[(__bridge id)kSecAttrSynchronizable];
    if (sync && ![sync isEqual:@NO] && !(query && [sync isEqual:(__bridge id)kSecAttrSynchronizableAny])) {
        return errSecUnimplemented;
    }
    id protectedStore = dictionary[(__bridge id)kSecUseDataProtectionKeychain];
    if (protectedStore && CFGetTypeID((__bridge CFTypeRef)protectedStore) != CFBooleanGetTypeID()) return errSecParam;
    id limit = dictionary[(__bridge id)kSecMatchLimit];
    if (limit && ![limit isEqual:(__bridge id)kSecMatchLimitOne] && ![limit isEqual:(__bridge id)kSecMatchLimitAll]) return errSecParam;
    for (id key in returnKeys()) {
        if (dictionary[key] && ![dictionary[key] isKindOfClass:NSNumber.class]) return errSecParam;
    }
    id data = dictionary[(__bridge id)kSecValueData];
    if (data && ![data isKindOfClass:NSData.class]) return errSecParam;
    id reference = dictionary[(__bridge id)kSecValuePersistentRef];
    if (reference && ![reference isKindOfClass:NSData.class]) return errSecParam;
    if (!itemClass && !reference) return errSecParam;
    return errSecSuccess;
}

static id copyReference(NSDictionary *attributes) {
    NSData *data = attributes[(__bridge id)kSecValueData];
    if ([attributes[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassKey]) {
        NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
        for (id key in @[(__bridge id)kSecAttrKeyType, (__bridge id)kSecAttrKeyClass, (__bridge id)kSecAttrKeySizeInBits]) {
            if (attributes[key]) parameters[key] = attributes[key];
        }
        return CFBridgingRelease(SecKeyCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)parameters, NULL));
    }
    if ([attributes[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassCertificate]) {
        return CFBridgingRelease(SecCertificateCreateWithData(NULL, (__bridge CFDataRef)data));
    }
    return nil;
}

static NSData *serialize(id value) {
    return [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
}

static NSData *identity(NSDictionary *attributes) {
    NSMutableArray *parts = [NSMutableArray arrayWithObject:attributes[(__bridge id)kSecClass]];
    for (id key in primaryAttributes(parts[0])) {
        [parts addObject:attributes[key] ?: ([key isEqual:(__bridge id)kSecAttrPort] ? @0 : @"")];
    }
    return serialize(parts);
}

static SecKeyRef keyFailure(OSStatus status, CFErrorRef *error) {
    if (error) *error = CFErrorCreate(NULL, kCFErrorDomainOSStatus, status, NULL);
    return NULL;
}

static NSDictionary *generationAttributes(NSDictionary *parameters, CFStringRef specific, OSStatus *status) {
    id nested = parameters[(__bridge id)specific];
    if (nested && ![nested isKindOfClass:NSDictionary.class]) { *status = errSecParam; return nil; }
    NSMutableDictionary *attributes = [parameters mutableCopy];
    [attributes removeObjectForKey:(__bridge id)kSecPrivateKeyAttrs];
    [attributes removeObjectForKey:(__bridge id)kSecPublicKeyAttrs];
    [attributes addEntriesFromDictionary:nested ?: @{}];
    NSSet *allowed = [NSSet setWithArray:@[
        (__bridge id)kSecAttrKeyType, (__bridge id)kSecAttrKeySizeInBits, (__bridge id)kSecAttrEffectiveKeySize,
        (__bridge id)kSecAttrLabel, (__bridge id)kSecAttrApplicationTag, (__bridge id)kSecAttrAccessGroup,
        (__bridge id)kSecAttrAccessible, (__bridge id)kSecAttrIsPermanent, (__bridge id)kSecAttrSynchronizable,
        (__bridge id)kSecAttrCanEncrypt, (__bridge id)kSecAttrCanDecrypt, (__bridge id)kSecAttrCanDerive,
        (__bridge id)kSecAttrCanSign, (__bridge id)kSecAttrCanVerify, (__bridge id)kSecAttrCanWrap,
        (__bridge id)kSecAttrCanUnwrap, (__bridge id)kSecUseDataProtectionKeychain,
    ]];
    for (id name in attributes) {
        if (![allowed containsObject:name]) { *status = errSecUnimplemented; return nil; }
    }
    id permanent = attributes[(__bridge id)kSecAttrIsPermanent];
    if (permanent && CFGetTypeID((__bridge CFTypeRef)permanent) != CFBooleanGetTypeID()) {
        *status = errSecParam;
        return nil;
    }
    NSMutableDictionary *check = [attributes mutableCopy];
    check[(__bridge id)kSecClass] = (__bridge id)kSecClassKey;
    *status = validate(check, NO);
    return *status ? nil : attributes;
}

static NSDictionary *ephemeralAttributes(NSDictionary *attributes) {
    NSMutableDictionary *result = [attributes mutableCopy];
    for (id name in @[(__bridge id)kSecAttrApplicationTag, (__bridge id)kSecAttrAccessGroup,
                      (__bridge id)kSecAttrAccessible, (__bridge id)kSecAttrSynchronizable,
                      (__bridge id)kSecUseDataProtectionKeychain]) {
        [result removeObjectForKey:name];
    }
    result[(__bridge id)kSecAttrIsPermanent] = @NO;
    return result;
}

static NSDictionary *recordForKey(NSDictionary *attributes, id key) {
    NSMutableDictionary *record = [attributes mutableCopy];
    record[(__bridge id)kSecClass] = (__bridge id)kSecClassKey;
    record[(__bridge id)kSecValueRef] = key;
    return record;
}

@implementation UnipaKeychainStore {
    NSString *_database;
    sqlite3 *_db;
    NSData *_namespace;
}

- (instancetype)initWithDatabasePath:(NSString *)database {
    if ((self = [super init])) _database = [database copy];
    return self;
}

- (void)dealloc {
    if (_db) sqlite3_close(_db);
}

- (OSStatus)open {
    if (_db) return errSecSuccess;
    struct stat info;
    NSString *directory = [_database stringByDeletingLastPathComponent];
    if (lstat(directory.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 077)) return errSecIO;
    NSString *file = _database;
    int fd = open(file.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return errSecIO;
    BOOL safe = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == getuid() && info.st_nlink == 1 && !(info.st_mode & 077);
    close(fd);
    if (!safe) return errSecIO;
    if (sqlite3_open_v2(file.fileSystemRepresentation, &_db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, NULL) != SQLITE_OK) goto failed;
    sqlite3_busy_timeout(_db, 5000);
    sqlite3_stmt *statement;
    if (sqlite3_prepare_v2(_db, "PRAGMA user_version", -1, &statement, NULL) != SQLITE_OK) goto failed;
    int version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : -1;
    sqlite3_finalize(statement);
    if (version != 0 && version != 1) goto failed;
    // DELETE journals inherit the database's 0600 mode and disappear after commit.
    if (sqlite3_exec(_db, "PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; BEGIN IMMEDIATE;"
                         "CREATE TABLE IF NOT EXISTS metadata (id INTEGER PRIMARY KEY CHECK(id=1), namespace BLOB NOT NULL);"
                         "INSERT OR IGNORE INTO metadata VALUES (1, randomblob(16));"
                         "CREATE TABLE IF NOT EXISTS items (id BLOB PRIMARY KEY NOT NULL, identity BLOB UNIQUE NOT NULL, attributes BLOB NOT NULL);"
                         "PRAGMA user_version=1; COMMIT;", NULL, NULL, NULL) != SQLITE_OK) goto failed;
    if (sqlite3_prepare_v2(_db, "SELECT namespace FROM metadata WHERE id=1", -1, &statement, NULL) != SQLITE_OK) goto failed;
    if (sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_bytes(statement, 0) == 16) {
        _namespace = [NSData dataWithBytes:sqlite3_column_blob(statement, 0) length:16];
    }
    sqlite3_finalize(statement);
    if (_namespace) return errSecSuccess;
failed:
    if (_db) sqlite3_close(_db);
    _db = NULL;
    return errSecIO;
}

- (NSData *)persistentReference:(NSData *)identifier {
    NSMutableData *reference = [NSMutableData dataWithBytes:referencePrefix length:sizeof(referencePrefix) - 1];
    [reference appendData:_namespace];
    [reference appendData:identifier];
    return reference;
}

- (BOOL)matches:(NSDictionary *)record query:(NSDictionary *)query {
    for (id key in query) {
        if ([optionKeys() containsObject:key]) continue;
        if ([key isEqual:(__bridge id)kSecValuePersistentRef]) {
            if (![query[key] isEqual:[self persistentReference:record[itemID]]]) return NO;
        } else if ([key isEqual:(__bridge id)kSecAttrSynchronizable] && [query[key] isEqual:(__bridge id)kSecAttrSynchronizableAny]) {
            continue;
        } else if (![query[key] isEqual:record[key] ?: ([key isEqual:(__bridge id)kSecAttrSynchronizable] ? @NO : nil)]) {
            return NO;
        }
    }
    return YES;
}

- (NSArray *)records:(NSDictionary *)query status:(OSStatus *)status {
    sqlite3_stmt *statement;
    if (sqlite3_prepare_v2(_db, "SELECT id, attributes FROM items ORDER BY rowid", -1, &statement, NULL) != SQLITE_OK) {
        *status = errSecIO;
        return nil;
    }
    NSMutableArray *records = [NSMutableArray array];
    int result;
    while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
        NSData *data = [NSData dataWithBytes:sqlite3_column_blob(statement, 1) length:sqlite3_column_bytes(statement, 1)];
        id attributes = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:NULL error:NULL];
        if (![attributes isKindOfClass:NSMutableDictionary.class] || sqlite3_column_bytes(statement, 0) != 16 ||
            validate(attributes, NO) != errSecSuccess || ![attributes[(__bridge id)kSecValueData] isKindOfClass:NSData.class]) {
            *status = errSecDecode;
            break;
        }
        attributes[itemID] = [NSData dataWithBytes:sqlite3_column_blob(statement, 0) length:16];
        if ([self matches:attributes query:query]) [records addObject:attributes];
    }
    if (result != SQLITE_DONE && *status == errSecSuccess) *status = errSecIO;
    sqlite3_finalize(statement);
    return *status == errSecSuccess ? records : nil;
}

- (id)resultFor:(NSDictionary *)record options:(NSDictionary *)options status:(OSStatus *)status {
    BOOL data = flag(options, kSecReturnData), attributes = flag(options, kSecReturnAttributes);
    BOOL reference = flag(options, kSecReturnRef), persistent = flag(options, kSecReturnPersistentRef);
    id ref = reference ? copyReference(record) : nil;
    if (reference && !ref) { *status = errSecUnimplemented; return nil; }
    int count = data + attributes + reference + persistent;
    if (!count) return nil;
    if (count == 1 && data) return record[(__bridge id)kSecValueData];
    if (count == 1 && reference) return ref;
    if (count == 1 && persistent) return [self persistentReference:record[itemID]];
    NSMutableDictionary *result = attributes ? [record mutableCopy] : [NSMutableDictionary dictionary];
    [result removeObjectForKey:itemID];
    [result removeObjectForKey:(__bridge id)kSecValueData];
    if (data) result[(__bridge id)kSecValueData] = record[(__bridge id)kSecValueData];
    if (reference) result[(__bridge id)kSecValueRef] = ref;
    if (persistent) result[(__bridge id)kSecValuePersistentRef] = [self persistentReference:record[itemID]];
    return result;
}

- (OSStatus)write:(NSDictionary *)attributes identifier:(NSData *)identifier adding:(BOOL)adding {
    NSData *data = serialize(attributes), *key = identity(attributes);
    if (!data || !key) return errSecParam;
    const char *sql = adding ? "INSERT INTO items (attributes,identity,id) VALUES (?,?,?)" : "UPDATE items SET attributes=?,identity=? WHERE id=?";
    sqlite3_stmt *statement;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) return errSecIO;
    sqlite3_bind_blob(statement, 1, data.bytes, (int)data.length, SQLITE_TRANSIENT);
    sqlite3_bind_blob(statement, 2, key.bytes, (int)key.length, SQLITE_TRANSIENT);
    sqlite3_bind_blob(statement, 3, identifier.bytes, (int)identifier.length, SQLITE_TRANSIENT);
    int result = sqlite3_step(statement);
    sqlite3_finalize(statement);
    return result == SQLITE_DONE ? errSecSuccess : (result == SQLITE_CONSTRAINT ? errSecDuplicateItem : errSecIO);
}

- (OSStatus)add:(CFDictionaryRef)input result:(CFTypeRef *)result {
    if (result) *result = NULL;
    if (!input || CFGetTypeID(input) != CFDictionaryGetTypeID()) return errSecParam;
    NSDictionary *options = (__bridge NSDictionary *)input;
    OSStatus status = validate(options, NO);
    if (status) return status;
    NSMutableDictionary *attributes = [options mutableCopy];
    for (id key in optionKeys()) [attributes removeObjectForKey:key];
    id reference = attributes[(__bridge id)kSecValueRef];
    id itemClass = attributes[(__bridge id)kSecClass];
    if (reference) {
        CFTypeRef ref = (__bridge CFTypeRef)reference;
        if ([itemClass isEqual:(__bridge id)kSecClassKey] && CFGetTypeID(ref) == SecKeyGetTypeID()) {
            NSDictionary *keyAttributes = CFBridgingRelease(SecKeyCopyAttributes((SecKeyRef)ref));
            for (id key in attributeKeys()) if (keyAttributes[key] && !attributes[key]) attributes[key] = keyAttributes[key];
            attributes[(__bridge id)kSecValueData] = CFBridgingRelease(SecKeyCopyExternalRepresentation((SecKeyRef)ref, NULL));
        } else if ([itemClass isEqual:(__bridge id)kSecClassCertificate] && CFGetTypeID(ref) == SecCertificateGetTypeID()) {
            attributes[(__bridge id)kSecValueData] = CFBridgingRelease(SecCertificateCopyData((SecCertificateRef)ref));
        } else return errSecParam;
        [attributes removeObjectForKey:(__bridge id)kSecValueRef];
    }
    if (!attributes[(__bridge id)kSecValueData]) {
        if ([itemClass isEqual:(__bridge id)kSecClassKey] || [itemClass isEqual:(__bridge id)kSecClassCertificate]) return errSecUnimplemented;
        attributes[(__bridge id)kSecValueData] = NSData.data;
    }
    if ([itemClass isEqual:(__bridge id)kSecClassKey]) {
        attributes[(__bridge id)kSecAttrIsPermanent] = @YES;
        id key = copyReference(attributes);
        if (!key) return errSecParam;
        NSDictionary *keyAttributes = CFBridgingRelease(SecKeyCopyAttributes((__bridge SecKeyRef)key));
        for (id name in @[(__bridge id)kSecAttrApplicationLabel, (__bridge id)kSecAttrKeySizeInBits, (__bridge id)kSecAttrEffectiveKeySize]) {
            if (!attributes[name] && keyAttributes[name]) attributes[name] = keyAttributes[name];
        }
    }
    if ([itemClass isEqual:(__bridge id)kSecClassCertificate]) {
        id certificate = copyReference(attributes);
        if (!certificate) return errSecParam;
        SecCertificateRef ref = (__bridge SecCertificateRef)certificate;
        attributes[(__bridge id)kSecAttrIssuer] = CFBridgingRelease(SecCertificateCopyNormalizedIssuerSequence(ref));
        attributes[(__bridge id)kSecAttrSubject] = CFBridgingRelease(SecCertificateCopyNormalizedSubjectSequence(ref));
        attributes[(__bridge id)kSecAttrSerialNumber] = CFBridgingRelease(SecCertificateCopySerialNumberData(ref, NULL));
    }
    for (id key in primaryAttributes(itemClass)) {
        if (!attributes[key]) attributes[key] = [key isEqual:(__bridge id)kSecAttrPort] ? @0 : @"";
    }
    attributes[(__bridge id)kSecAttrSynchronizable] = @NO;
    if (!serialize(attributes)) return errSecParam;
    NSUUID *uuid = NSUUID.UUID;
    uuid_t bytes;
    [uuid getUUIDBytes:bytes];
    NSData *identifier = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    NSMutableDictionary *record = [attributes mutableCopy];
    record[itemID] = identifier;
    if (flag(options, kSecReturnRef) && !copyReference(record)) return errSecUnimplemented;
    id value = nil;
    @synchronized (self) {
        status = [self open];
        if (status) return status;
        // Persistent references include the store namespace, which is loaded by open.
        value = [self resultFor:record options:options status:&status];
        if (!status) status = [self write:attributes identifier:identifier adding:YES];
    }
    if (!status && result && value) *result = CFBridgingRetain(value);
    return status;
}

- (OSStatus)copyMatching:(CFDictionaryRef)input result:(CFTypeRef *)result {
    if (result) *result = NULL;
    if (!input || CFGetTypeID(input) != CFDictionaryGetTypeID()) return errSecParam;
    NSDictionary *query = (__bridge NSDictionary *)input;
    OSStatus status = validate(query, YES);
    if (status) return status;
    @synchronized (self) {
        status = [self open];
        if (status) return status;
        NSArray *records = [self records:query status:&status];
        if (status) return status;
        if (!records.count) return errSecItemNotFound;
        BOOL all = [query[(__bridge id)kSecMatchLimit] isEqual:(__bridge id)kSecMatchLimitAll];
        NSMutableArray *values = [NSMutableArray array];
        for (NSDictionary *record in records) {
            id value = [self resultFor:record options:query status:&status];
            if (status) return status;
            if (value) [values addObject:value];
            if (!all) break;
        }
        if (result && values.count) *result = CFBridgingRetain(all ? values : values.firstObject);
        return errSecSuccess;
    }
}

- (OSStatus)change:(CFDictionaryRef)input attributes:(CFDictionaryRef)updates {
    if (!input || CFGetTypeID(input) != CFDictionaryGetTypeID()) return errSecParam;
    NSDictionary *query = (__bridge NSDictionary *)input;
    OSStatus status = validate(query, YES);
    if (status) return status;
    if (updates) {
        if (CFGetTypeID(updates) != CFDictionaryGetTypeID()) return errSecParam;
        NSDictionary *changes = (__bridge NSDictionary *)updates;
        for (id key in changes) {
            if (![attributeKeys() containsObject:key] || [key isEqual:(__bridge id)kSecClass]) return errSecParam;
        }
        NSMutableDictionary *check = [changes mutableCopy];
        check[(__bridge id)kSecClass] = query[(__bridge id)kSecClass] ?: (__bridge id)kSecClassGenericPassword;
        status = validate(check, NO);
        if (status) return status;
    }
    @synchronized (self) {
        status = [self open];
        if (status) return status;
        if (sqlite3_exec(_db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return errSecIO;
        NSArray *records = [self records:query status:&status];
        if (!status && !records.count) status = errSecItemNotFound;
        for (NSDictionary *record in records) {
            if (status) break;
            if (updates) {
                id itemClass = record[(__bridge id)kSecClass];
                if (((__bridge NSDictionary *)updates)[(__bridge id)kSecValueData] &&
                    ([itemClass isEqual:(__bridge id)kSecClassKey] || [itemClass isEqual:(__bridge id)kSecClassCertificate])) {
                    status = errSecUnimplemented;
                    break;
                }
                NSMutableDictionary *attributes = [record mutableCopy];
                [attributes removeObjectForKey:itemID];
                [attributes addEntriesFromDictionary:(__bridge NSDictionary *)updates];
                if ([itemClass isEqual:(__bridge id)kSecClassKey] && !copyReference(attributes)) {
                    status = errSecParam;
                    break;
                }
                status = [self write:attributes identifier:record[itemID] adding:NO];
            } else {
                sqlite3_stmt *statement;
                if (sqlite3_prepare_v2(_db, "DELETE FROM items WHERE id=?", -1, &statement, NULL) != SQLITE_OK) { status = errSecIO; break; }
                NSData *identifier = record[itemID];
                sqlite3_bind_blob(statement, 1, identifier.bytes, (int)identifier.length, SQLITE_TRANSIENT);
                if (sqlite3_step(statement) != SQLITE_DONE) status = errSecIO;
                sqlite3_finalize(statement);
            }
        }
        if (sqlite3_exec(_db, status ? "ROLLBACK" : "COMMIT", NULL, NULL, NULL) != SQLITE_OK) {
            sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
            return errSecIO;
        }
        return status;
    }
}

- (OSStatus)update:(CFDictionaryRef)query attributes:(CFDictionaryRef)attributes {
    if (!attributes) return errSecParam;
    return [self change:query attributes:attributes];
}

- (SecKeyRef)createRandomKey:(CFDictionaryRef)input error:(CFErrorRef *)error {
    if (error) *error = NULL;
    if (!input || CFGetTypeID(input) != CFDictionaryGetTypeID()) return keyFailure(errSecParam, error);
    NSDictionary *parameters = (__bridge NSDictionary *)input;
    OSStatus status = errSecSuccess;
    NSDictionary *privateAttributes = generationAttributes(parameters, kSecPrivateKeyAttrs, &status);
    if (status) return keyFailure(status, error);
    NSDictionary *publicAttributes = generationAttributes(parameters, kSecPublicKeyAttrs, &status);
    if (status) return keyFailure(status, error);

    NSMutableDictionary *ephemeral = [ephemeralAttributes(parameters) mutableCopy];
    ephemeral[(__bridge id)kSecPrivateKeyAttrs] = ephemeralAttributes(privateAttributes);
    ephemeral[(__bridge id)kSecPublicKeyAttrs] = ephemeralAttributes(publicAttributes);
    // Calls from this image reach the original API; permanence is handled below.
    id privateKey = CFBridgingRelease(SecKeyCreateRandomKey((__bridge CFDictionaryRef)ephemeral, error));
    if (!privateKey) return NULL;
    BOOL savePrivate = flag(privateAttributes, kSecAttrIsPermanent);
    BOOL savePublic = flag(publicAttributes, kSecAttrIsPermanent);
    if (!savePrivate && !savePublic) return (SecKeyRef)CFBridgingRetain(privateKey);
    id publicKey = savePublic ? CFBridgingRelease(SecKeyCopyPublicKey((__bridge SecKeyRef)privateKey)) : nil;
    if (savePublic && !publicKey) return keyFailure(errSecParam, error);

    @synchronized (self) {
        status = [self open];
        if (status) return keyFailure(status, error);
        if (sqlite3_exec(_db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) return keyFailure(errSecIO, error);
        NSMutableArray *records = [NSMutableArray array];
        if (savePrivate) [records addObject:recordForKey(privateAttributes, privateKey)];
        if (savePublic) [records addObject:recordForKey(publicAttributes, publicKey)];
        for (NSDictionary *record in records) {
            status = [self add:(__bridge CFDictionaryRef)record result:NULL];
            if (status) break;
        }
        if (sqlite3_exec(_db, status ? "ROLLBACK" : "COMMIT", NULL, NULL, NULL) != SQLITE_OK) {
            sqlite3_exec(_db, "ROLLBACK", NULL, NULL, NULL);
            status = errSecIO;
        }
    }
    return status ? keyFailure(status, error) : (SecKeyRef)CFBridgingRetain(privateKey);
}

- (OSStatus)deleteMatching:(CFDictionaryRef)query {
    return [self change:query attributes:NULL];
}
@end
